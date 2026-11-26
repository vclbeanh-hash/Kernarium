// SPDX-License-Identifier: GPL-2.0-or-later
// Minimal iOS 16 boot diagnostic frontend. Uses the upstream runtime loader.
#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CommonCrypto/CommonDigest.h>
#include <unistd.h>
#include <cstdio>
#import "../../GuestHost/Sources/KernariumRuntimeLoader.h"

@interface LegacyMetalView : MTKView
@property(nonatomic) BOOL guestRunning;
@end
@implementation LegacyMetalView
- (void)send:(NSSet<UITouch *> *)touches pressed:(int)pressed {
    if (!self.guestRunning || !self.bounds.size.width || !self.bounds.size.height) return;
    UITouch *touch = touches.anyObject;
    CGPoint p = [touch locationInView:self];
    uint32_t x = (uint32_t)MAX(0, MIN(KERNARIUM_RUNTIME_TOUCH_MAXIMUM, p.x / self.bounds.size.width * KERNARIUM_RUNTIME_TOUCH_MAXIMUM));
    uint32_t y = (uint32_t)MAX(0, MIN(KERNARIUM_RUNTIME_TOUCH_MAXIMUM, p.y / self.bounds.size.height * KERNARIUM_RUNTIME_TOUCH_MAXIMUM));
    kernarium_runtime_loader_send_touch(0, x, y, pressed);
}
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event { [self send:touches pressed:1]; }
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event { [self send:touches pressed:1]; }
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event { [self send:touches pressed:0]; }
- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    if (self.guestRunning) kernarium_runtime_loader_cancel_touch(0);
}
@end

@interface LegacyController : UIViewController <UIDocumentPickerDelegate>
@property(nonatomic,strong) LegacyMetalView *screen;
@property(nonatomic,strong) UITextView *console;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UIButton *startButton;
@property(nonatomic,strong) UIButton *stopButton;
@property(nonatomic) BOOL running;
@property(nonatomic) BOOL importing;
@property(nonatomic,strong) UIButton *romButton;
@property(nonatomic,strong) UIButton *settingsButton;
@property(nonatomic,strong) NSPipe *hostLogPipe;
@property(nonatomic,strong) NSFileHandle *hostLogReader;
@end
@implementation LegacyController
- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.status = [UILabel new];
    self.status.text = @"LEM Andarium Lite • Android 17";
    self.status.numberOfLines = 0;
    self.startButton = [self button:@"Khởi động" action:@selector(startGuest)];
    self.stopButton = [self button:@"Dừng" action:@selector(stopGuest)];
    self.stopButton.enabled = NO;
    UIButton *back = [self button:@"Back" action:@selector(backKey)];
    UIButton *home = [self button:@"Home" action:@selector(homeKey)];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[self.startButton,self.stopButton,back,home]];
    buttons.distribution = UIStackViewDistributionFillEqually;
    self.romButton = [self button:@"Kho ROM" action:@selector(romMenu)];
    self.settingsButton = [self button:@"Cấu hình" action:@selector(settingsMenu)];
    UIStackView *options = [[UIStackView alloc] initWithArrangedSubviews:@[self.romButton,self.settingsButton]];
    options.distribution = UIStackViewDistributionFillEqually;
    self.screen = [[LegacyMetalView alloc] initWithFrame:CGRectZero device:MTLCreateSystemDefaultDevice()];
    self.screen.backgroundColor = UIColor.blackColor;
    self.screen.clearColor = MTLClearColorMake(0,0,0,1);
    self.screen.paused = YES;
    self.screen.enableSetNeedsDisplay = YES;
    self.screen.autoResizeDrawable = NO;
    self.screen.drawableSize = CGSizeMake(720,1280);
    self.screen.contentMode = UIViewContentModeScaleAspectFit;
    self.console = [UITextView new];
    self.console.editable = NO;
    self.console.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.console.text = @"Host + Android console • Build diagnostic\n";
    [self captureHostLogs];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.status,buttons,options,self.screen,self.console]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [stack.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [buttons.heightAnchor constraintEqualToConstant:44],
        [options.heightAnchor constraintEqualToConstant:36],
        [self.console.heightAnchor constraintEqualToConstant:150]
    ]];
    [self.screen setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(stopGuest) name:UIApplicationDidEnterBackgroundNotification object:nil];
}
- (void)captureHostLogs {
    self.hostLogPipe = [NSPipe pipe];
    self.hostLogReader = self.hostLogPipe.fileHandleForReading;
    int fd = self.hostLogPipe.fileHandleForWriting.fileDescriptor;
    if (dup2(fd, STDERR_FILENO) < 0 || dup2(fd, STDOUT_FILENO) < 0) {
        [self appendLog:@"Unable to redirect host output.\n"];
        return;
    }
    setvbuf(stderr, nullptr, _IONBF, 0);
    setvbuf(stdout, nullptr, _IONBF, 0);
    __weak LegacyController *weakSelf = self;
    self.hostLogReader.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (!data.length) { handle.readabilityHandler = nil; return; }
        NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!line) line = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf appendLog:line]; });
    };
}
- (void)appendLog:(NSString *)line {
    NSString *combined = [self.console.text stringByAppendingString:line ?: @""];
    if (combined.length > 60000) combined = [combined substringFromIndex:combined.length-60000];
    self.console.text = combined;
    [self.console scrollRangeToVisible:NSMakeRange(combined.length,0)];
}
- (NSURL *)guestDirectory {
    NSURL *library = [[NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask] firstObject];
    return [library URLByAppendingPathComponent:@"Guest" isDirectory:YES];
}
- (NSURL *)romDirectory {
    return [[self guestDirectory] URLByAppendingPathComponent:@"ROM" isDirectory:YES];
}
- (NSArray<NSString *> *)romFiles {
    return @[@"release-manifest.json",@"guest/system.img",@"guest/partition-layout.json",@"boot/kernel-command-line.txt"];
}
- (BOOL)hasROM {
    for (NSString *file in [self romFiles])
        if (![NSFileManager.defaultManager fileExistsAtPath:[[self romDirectory] URLByAppendingPathComponent:file].path]) return NO;
    return YES;
}
- (NSDictionary *)jsonAt:(NSURL *)url {
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) return nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
- (NSString *)hashFile:(NSURL *)url {
    NSInputStream *stream = [NSInputStream inputStreamWithURL:url];
    if (!stream) return nil;
    [stream open];
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    uint8_t *buffer = (uint8_t *)malloc(1024*1024);
    if (!buffer) { [stream close]; return nil; }
    NSInteger count;
    while ((count = [stream read:buffer maxLength:1024*1024]) > 0)
        CC_SHA256_Update(&ctx, buffer, (CC_LONG)count);
    free(buffer);
    [stream close];
    if (count < 0) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest,&ctx);
    NSMutableString *hex = [NSMutableString string];
    for (unsigned char byte : digest) [hex appendFormat:@"%02x",(unsigned int)byte];
    return hex;
}
- (void)romMenu {
    if (self.running || self.importing) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Kho ROM" message:[self hasROM] ? @"ROM đã lưu trong máy. Không cần nhập lại khi cập nhật IPA." : @"Tải ROM chính thức, giải nén .tar.gz bằng Filza hoặc trên máy tính, rồi chọn thư mục chứa release-manifest.json. Chỉ cần nhập một lần." preferredStyle:UIAlertControllerStyleAlert];
    [menu addAction:[UIAlertAction actionWithTitle:@"Tải ROM chính thức" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSURL *url = [NSURL URLWithString:@"https://github.com/imxieyi/Kernarium/releases/download/andarium-1.1/lineage24-mainline6.18-4k-20261121-los24-r29.tar.gz"];
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }]];
    if (![self hasROM]) [menu addAction:[UIAlertAction actionWithTitle:@"Nhập thư mục đã giải nén" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        [self presentViewController:picker animated:YES completion:nil];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:menu animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *source = urls.firstObject;
    if (!source || self.running || self.importing || [self hasROM]) return;
    self.importing = YES;
    self.startButton.enabled = NO;
    self.romButton.enabled = NO;
    self.status.text = @"Đang nhập và kiểm tra ROM...";
    BOOL scoped = [source startAccessingSecurityScopedResource];
    NSURL *parent = [self guestDirectory];
    NSURL *destination = [self romDirectory];
    NSArray *files = [self romFiles];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSError *error = nil;
        NSURL *stage = [parent URLByAppendingPathComponent:[@"ROM-import-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
        NSString *problem = nil;
        if (![fm createDirectoryAtURL:stage withIntermediateDirectories:YES attributes:nil error:&error])
            problem = error.localizedDescription;
        for (NSString *file in files) {
            if (problem) break;
            NSURL *from = [source URLByAppendingPathComponent:file];
            NSURL *to = [stage URLByAppendingPathComponent:file];
            NSNumber *regular = nil;
            NSNumber *symlink = nil;
            [from getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
            [from getResourceValue:&symlink forKey:NSURLIsSymbolicLinkKey error:nil];
            if (!regular.boolValue || symlink.boolValue) { problem = [@"Thiếu hoặc không hợp lệ: " stringByAppendingString:file]; break; }
            if (![fm createDirectoryAtURL:to.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error] ||
                ![fm copyItemAtURL:from toURL:to error:&error]) { problem = error.localizedDescription; break; }
        }
        if (!problem) {
            NSDictionary *manifest = [self jsonAt:[stage URLByAppendingPathComponent:@"release-manifest.json"]];
            NSDictionary *layout = [self jsonAt:[stage URLByAppendingPathComponent:@"guest/partition-layout.json"]];
            NSDictionary *system = [layout[@"system_disk"] isKindOfClass:NSDictionary.class] ? layout[@"system_disk"] : nil;
            NSURL *image = [stage URLByAppendingPathComponent:@"guest/system.img"];
            NSNumber *size = nil;
            [image getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
            NSDictionary *android = [manifest[@"android"] isKindOfClass:NSDictionary.class] ? manifest[@"android"] : nil;
            NSDictionary *kernel = [manifest[@"kernel"] isKindOfClass:NSDictionary.class] ? manifest[@"kernel"] : nil;
            if (![manifest[@"release_id"] isEqual:@"20261121-los24-r29"] ||
                ![manifest[@"acceptance"] isEqual:@"accepted"] ||
                ![manifest[@"product_family"] isEqual:@"lineage-24-mainline-6.18-4k"] ||
                ![android[@"major"] isEqual:@17] || ![kernel[@"page_size"] isEqual:@4096] ||
                ![layout[@"schema_version"] isEqual:@2] ||
                !size || ![size isEqual:system[@"size_bytes"]]) problem = @"ROM không đúng phiên bản r29 / 4 KiB hoặc ảnh đĩa không đầy đủ.";
            else {
                NSString *hash = [self hashFile:image];
                if (!hash || ![hash isEqual:system[@"sha256"]]) problem = @"SHA-256 ảnh hệ thống không khớp partition-layout.";
            }
        }
        if (!problem && ![fm moveItemAtURL:stage toURL:destination error:&error]) problem = error.localizedDescription;
        if (problem) [fm removeItemAtURL:stage error:nil];
        if (scoped) [source stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.importing = NO;
            self.startButton.enabled = YES;
            self.romButton.enabled = YES;
            self.status.text = problem ? @"Nhập ROM thất bại" : @"ROM đã nhập • sẵn sàng thử khởi động";
            [self appendLog:[NSString stringWithFormat:@"\n%@\n",problem ?: @"ROM imported; system image SHA-256 matches layout."]];
        });
    });
}
- (uint32_t)memoryMiB { NSInteger v = [NSUserDefaults.standardUserDefaults integerForKey:@"guestRAM"]; return v > 0 ? (uint32_t)v : 1024; }
- (uint32_t)cpuCount { NSInteger v = [NSUserDefaults.standardUserDefaults integerForKey:@"guestCPU"]; return v > 0 ? (uint32_t)v : 2; }
- (uint32_t)dataGiB { NSInteger v = [NSUserDefaults.standardUserDefaults integerForKey:@"guestDisk"]; return v > 0 ? (uint32_t)v : 8; }
- (void)choose:(NSString *)title key:(NSString *)key values:(NSArray<NSNumber *> *)values unit:(NSString *)unit {
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:title message:@"Áp dụng lần khởi động tiếp theo." preferredStyle:UIAlertControllerStyleAlert];
    for (NSNumber *value in values) [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ %@",value,unit] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [NSUserDefaults.standardUserDefaults setInteger:value.integerValue forKey:key];
        self.status.text = [NSString stringWithFormat:@"%u MiB RAM • %u vCPU • %u GiB ổ đĩa",[self memoryMiB],[self cpuCount],[self dataGiB]];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:menu animated:YES completion:nil];
}
- (void)settingsMenu {
    if (self.running || self.importing) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Cấu hình máy ảo" message:[NSString stringWithFormat:@"RAM: %u MiB • CPU: %u • Ổ đĩa: %u GiB. Ổ đĩa chỉ mở rộng, không thu nhỏ.",[self memoryMiB],[self cpuCount],[self dataGiB]] preferredStyle:UIAlertControllerStyleAlert];
    [menu addAction:[UIAlertAction actionWithTitle:@"RAM" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        uint32_t ceiling = kernarium_runtime_loader_maximum_guest_memory_mib([self cpuCount],kernarium_runtime_loader_launch_memory_set());
        NSMutableArray *values = [NSMutableArray array];
        for (NSNumber *n in @[@512,@768,@1024,@1536,@2048,@2560,@3072]) if (n.unsignedIntValue <= ceiling && kernarium_runtime_loader_guest_memory_admitted(n.unsignedIntValue)) [values addObject:n];
        [self choose:@"RAM (MiB)" key:@"guestRAM" values:values unit:@"MiB"];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"CPU" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        uint32_t limit = kernarium_runtime_loader_application_vcpu_limit((uint32_t)NSProcessInfo.processInfo.activeProcessorCount);
        NSMutableArray *values = [NSMutableArray array];
        for (uint32_t n=1;n<=MIN(4U,limit);++n) [values addObject:@(n)];
        [self choose:@"CPU" key:@"guestCPU" values:values unit:@"vCPU"];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Bộ nhớ lưu trữ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSDictionary *layout = [self jsonAt:[[self romDirectory] URLByAppendingPathComponent:@"guest/partition-layout.json"]];
        NSDictionary *range = layout[@"data_disk"][@"capacity_gib"];
        uint32_t maximum = range ? [range[@"maximum"] unsignedIntValue] : 8;
        uint32_t minimum = range ? [range[@"minimum"] unsignedIntValue] : 8;
        NSMutableArray *values = [NSMutableArray array];
        for (NSNumber *n in @[@8,@16,@32,@64]) if (n.unsignedIntValue >= minimum && n.unsignedIntValue <= maximum) [values addObject:n];
        [self choose:@"Dung lượng yêu cầu" key:@"guestDisk" values:values unit:@"GiB"];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:menu animated:YES completion:nil];
}
- (void)startGuest {
    if (self.running || self.importing) return;
    if (![self hasROM]) { [self romMenu]; return; }
    NSString *release = [self romDirectory].path;
    const uint32_t ram = [self memoryMiB], cpu = [self cpuCount], storage = [self dataGiB];
    for (NSString *file in @[@"release-manifest.json",@"guest/system.img",@"guest/partition-layout.json",@"boot/kernel-command-line.txt"]) {
        if (![NSFileManager.defaultManager fileExistsAtPath:[release stringByAppendingPathComponent:file]]) {
            [self appendLog:[NSString stringWithFormat:@"Missing image: %@\n",file]]; return;
        }
    }
    // UML UBD paths must not contain spaces. Match upstream Library/Guest.
    NSURL *library = [[NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *dir = [library URLByAppendingPathComponent:@"Guest" isDirectory:YES];
    if (!dir) { [self appendLog:@"Cannot locate Library/Guest.\n"]; return; }
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:&error]) {
        [self appendLog:error.localizedDescription]; return;
    }
    NSString *disk = [[dir URLByAppendingPathComponent:@"android-data.img"] path];
    NSString *record = [[dir URLByAppendingPathComponent:@"session.json"] path];
    [self appendLog:@"\n--- Start diagnostic ---\n"];
    [self appendLog:@"Data disk: Library/Guest/android-data.img\n"];
    [self appendLog:[NSString stringWithFormat:@"iOS %@, RAM %llu MiB\n",UIDevice.currentDevice.systemVersion,(unsigned long long)(NSProcessInfo.processInfo.physicalMemory >> 20)]];
    NSString *frameworks = NSBundle.mainBundle.privateFrameworksPath;
    NSError *listError = nil;
    NSArray *entries = frameworks ? [NSFileManager.defaultManager contentsOfDirectoryAtPath:frameworks error:&listError] : nil;
    [self appendLog:[NSString stringWithFormat:@"Frameworks: %@\n",entries ? [entries componentsJoinedByString:@", "] : (listError.localizedDescription ?: @"missing")]];
    self.running = YES;
    self.startButton.enabled = NO;
    self.stopButton.enabled = YES;
    self.status.text = [NSString stringWithFormat:@"Starting • %u MiB / %u vCPU / Softpipe",ram,cpu];
    self.romButton.enabled = NO; self.settingsButton.enabled = NO;
    self.screen.guestRunning = YES;
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    __weak LegacyController *weakSelf = self;
    kernarium_runtime_loader_set_console_output_handler(^(NSData *data) {
        NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!line) return;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf appendLog:line]; });
    });
    LegacyMetalView *screen = self.screen;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        std::fprintf(stderr, "Stage 1: selecting Android runtime\n");
        int result = kernarium_runtime_loader_select(KERNARIUM_RUNTIME_GUEST_ANDROID);
        std::fprintf(stderr, "Stage 1 result: %d\n", result);
        if (result == 0) {
            std::fprintf(stderr, "Stage 2: guest memory admission (%u MiB)\n",ram);
            if (!kernarium_runtime_loader_guest_memory_admitted(ram) || ram > kernarium_runtime_loader_maximum_guest_memory_mib(cpu,kernarium_runtime_loader_launch_memory_set())) {
                result = -1;
                dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf appendLog:@"Host memory admission refused selected RAM.\n"]; });
            } else {
                kernarium_runtime_boot boot = {};
                boot.struct_size = sizeof(boot);
                boot.width = 720; boot.height = 1280; boot.dots_per_inch = 240;
                boot.guest_memory_mib = ram; boot.guest_processor_count = cpu;
                boot.android_boot_mode = KERNARIUM_RUNTIME_ANDROID_BOOT_NORMAL;
                boot.android_data_disk_path = disk.fileSystemRepresentation;
                boot.android_release_path = release.fileSystemRepresentation;
                boot.android_data_gib = storage;
                boot.session_record_path = record.fileSystemRepresentation;
                const auto budget = kernarium_runtime_loader_launch_memory_set();
                boot.gpu_budget_application_mib = budget.application_mib;
                boot.gpu_budget_engine_mib = budget.engine_mib;
                boot.gpu_budget_headroom_mib = budget.headroom_mib;
                boot.android_aot_disabled = 1;
                boot.use_jit = 0;
                boot.android_camera_mode = KERNARIUM_RUNTIME_ANDROID_CAMERA_BLOCKED;
                std::fprintf(stderr, "Stage 3: entering Android runtime\n");
                result = kernarium_runtime_loader_run(screen, &boot);
                std::fprintf(stderr, "Stage 3 result: %d\n", result);
            }
        }
        kernarium_runtime_loader_set_console_output_handler(nil);
        dispatch_async(dispatch_get_main_queue(), ^{
            LegacyController *controller = weakSelf;
            controller.running = NO;
            controller.screen.guestRunning = NO;
            controller.startButton.enabled = YES;
            controller.stopButton.enabled = NO;
            controller.romButton.enabled = YES; controller.settingsButton.enabled = YES;
            controller.status.text = [NSString stringWithFormat:@"Runtime returned %d",result];
            [controller appendLog:[NSString stringWithFormat:@"\nRuntime returned %d\n",result]];
            UIApplication.sharedApplication.idleTimerDisabled = NO;
        });
    });
}
- (void)stopGuest { if (self.running) kernarium_runtime_loader_request_stop(); }
- (void)backKey { if (self.running) { kernarium_runtime_loader_send_key(158,1); kernarium_runtime_loader_send_key(158,0); } }
- (void)homeKey { if (self.running) { kernarium_runtime_loader_send_key(102,1); kernarium_runtime_loader_send_key(102,0); } }
@end

@interface LegacyAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation LegacyAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [LegacyController new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end
int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(LegacyAppDelegate.class)); }
}
