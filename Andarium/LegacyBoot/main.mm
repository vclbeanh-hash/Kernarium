// SPDX-License-Identifier: GPL-2.0-or-later
// Minimal iOS 16 boot diagnostic frontend. Uses the upstream runtime loader.
#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>
#import "../../GuestHost/Sources/KernariumRuntimeLoader.h"

@interface LegacyMetalView : MTKView
@property(nonatomic) BOOL guestRunning;
@end
@implementation LegacyMetalView
- (void)send:(NSSet<UITouch *> *)touches pressed:(int)pressed {
    if (!self.guestRunning || !self.bounds.size.width || !self.bounds.size.height) return;
    UITouch *touch = touches.anyObject;
    CGPoint p = [touch locationInView:self];
    uint32_t x = (uint32_t)MAX(0, MIN(719, p.x / self.bounds.size.width * 720));
    uint32_t y = (uint32_t)MAX(0, MIN(1279, p.y / self.bounds.size.height * 1280));
    kernarium_runtime_loader_send_touch(0, x, y, pressed);
}
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event { [self send:touches pressed:1]; }
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event { [self send:touches pressed:1]; }
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event { [self send:touches pressed:0]; }
- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    if (self.guestRunning) kernarium_runtime_loader_cancel_touch(0);
}
@end

@interface LegacyController : UIViewController
@property(nonatomic,strong) LegacyMetalView *screen;
@property(nonatomic,strong) UITextView *console;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UIButton *startButton;
@property(nonatomic,strong) UIButton *stopButton;
@property(nonatomic) BOOL running;
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
    self.status.text = @"Android 17 • iOS 16 boot test";
    self.status.numberOfLines = 0;
    self.startButton = [self button:@"Khởi động" action:@selector(startGuest)];
    self.stopButton = [self button:@"Dừng" action:@selector(stopGuest)];
    self.stopButton.enabled = NO;
    UIButton *back = [self button:@"Back" action:@selector(backKey)];
    UIButton *home = [self button:@"Home" action:@selector(homeKey)];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[self.startButton,self.stopButton,back,home]];
    buttons.distribution = UIStackViewDistributionFillEqually;
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
    self.console.text = @"Serial console\n";
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.status,buttons,self.screen,self.console]];
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
        [self.console.heightAnchor constraintEqualToConstant:150]
    ]];
    [self.screen setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(stopGuest) name:UIApplicationDidEnterBackgroundNotification object:nil];
}
- (void)appendLog:(NSString *)line {
    NSString *combined = [self.console.text stringByAppendingString:line ?: @""];
    if (combined.length > 60000) combined = [combined substringFromIndex:combined.length-60000];
    self.console.text = combined;
    [self.console scrollRangeToVisible:NSMakeRange(combined.length,0)];
}
- (void)startGuest {
    if (self.running) return;
    NSString *release = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"andarium-system"];
    for (NSString *file in @[@"release-manifest.json",@"guest/system.img",@"guest/partition-layout.json",@"boot/kernel-command-line.txt"]) {
        if (![NSFileManager.defaultManager fileExistsAtPath:[release stringByAppendingPathComponent:file]]) {
            [self appendLog:[NSString stringWithFormat:@"Missing image: %@\n",file]]; return;
        }
    }
    NSURL *dir = [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:&error]) {
        [self appendLog:error.localizedDescription]; return;
    }
    NSString *disk = [[dir URLByAppendingPathComponent:@"android-data.img"] path];
    NSString *record = [[dir URLByAppendingPathComponent:@"session.json"] path];
    self.running = YES;
    self.startButton.enabled = NO;
    self.stopButton.enabled = YES;
    self.status.text = @"Starting Android • 1 GiB / 2 vCPU / Softpipe";
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
        int result = kernarium_runtime_loader_select(1);
        if (result == 0) {
            if (!kernarium_runtime_loader_guest_memory_admitted(1024)) {
                result = -1;
                dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf appendLog:@"Host memory admission refused 1024 MiB.\n"]; });
            } else {
                kernarium_runtime_boot boot = {};
                boot.struct_size = sizeof(boot);
                boot.width = 720; boot.height = 1280; boot.dots_per_inch = 240;
                boot.guest_memory_mib = 1024; boot.guest_processor_count = 2;
                boot.android_boot_mode = KERNARIUM_RUNTIME_ANDROID_BOOT_NORMAL;
                boot.android_data_disk_path = disk.fileSystemRepresentation;
                boot.android_release_path = release.fileSystemRepresentation;
                boot.android_data_gib = 8;
                boot.session_record_path = record.fileSystemRepresentation;
                const auto budget = kernarium_runtime_loader_launch_memory_set();
                boot.gpu_budget_application_mib = budget.application_mib;
                boot.gpu_budget_engine_mib = budget.engine_mib;
                boot.gpu_budget_headroom_mib = budget.headroom_mib;
                boot.android_aot_disabled = 1;
                boot.use_jit = 0;
                boot.android_camera_mode = KERNARIUM_RUNTIME_ANDROID_CAMERA_BLOCKED;
                result = kernarium_runtime_loader_run(screen, &boot);
            }
        }
        kernarium_runtime_loader_set_console_output_handler(nil);
        dispatch_async(dispatch_get_main_queue(), ^{
            LegacyController *controller = weakSelf;
            controller.running = NO;
            controller.screen.guestRunning = NO;
            controller.startButton.enabled = YES;
            controller.stopButton.enabled = NO;
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
