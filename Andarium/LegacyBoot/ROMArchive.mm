// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>
#include <archive.h>
#include <archive_entry.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>
#include <algorithm>
#include <set>
#include <string>

// Only the four runtime files are extracted. Archive paths, links, modes
// and ownership are never used as filesystem instructions.
NSString *LegacyExtractROM(NSURL *source, NSURL *stage) {
    const std::string root = "lineage24-mainline6.18-4k-20261121-los24-r29/";
    const std::set<std::string> wanted = {
        "release-manifest.json", "guest/system.img",
        "guest/partition-layout.json", "boot/kernel-command-line.txt"};
    std::set<std::string> seen;
    struct archive *reader = archive_read_new();
    if (!reader) return @"Không tạo được bộ đọc TAR.";
    archive_read_support_filter_gzip(reader);
    archive_read_support_format_tar(reader);
    NSString *problem = nil;
    if (archive_read_open_filename(reader, source.fileSystemRepresentation, 1024*1024) != ARCHIVE_OK)
        problem = [NSString stringWithFormat:@"Không mở được ROM: %s", archive_error_string(reader) ?: "unknown"];
    struct archive_entry *entry = nullptr;
    int result = ARCHIVE_EOF;
    while (!problem && (result = archive_read_next_header(reader,&entry)) == ARCHIVE_OK) {
        const char *raw = archive_entry_pathname(entry);
        std::string name = raw ? raw : "";
        while (name.starts_with("./")) name.erase(0,2);
        if (name.starts_with(root)) name.erase(0,root.size());
        if (!wanted.contains(name)) {
            if (archive_read_data_skip(reader) != ARCHIVE_OK) problem = @"Không đọc được mục TAR.";
            continue;
        }
        const int64_t size = archive_entry_size(entry);
        const bool disk = name == "guest/system.img";
        if (!seen.insert(name).second || archive_entry_filetype(entry) != AE_IFREG ||
            archive_entry_hardlink(entry) || archive_entry_symlink(entry) ||
            size <= 0 || size > (disk ? (32LL<<30) : (16LL<<20))) {
            problem = @"ROM chứa mục bắt buộc không hợp lệ.";
            break;
        }
        NSURL *dest = [stage URLByAppendingPathComponent:[NSString stringWithUTF8String:name.c_str()]];
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtURL:dest.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error]) {
            problem = error.localizedDescription; break;
        }
        int fd = open(dest.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
        if (fd < 0) { problem = [NSString stringWithFormat:@"Không tạo được tệp ROM: %s",strerror(errno)]; break; }
        const void *buffer = nullptr; size_t bytes = 0; la_int64_t offset = 0;
        int rc;
        while ((rc = archive_read_data_block(reader,&buffer,&bytes,&offset)) == ARCHIVE_OK) {
            if (offset < 0 || offset > size || bytes > (uint64_t)(size-offset)) {
                problem = @"Ảnh đĩa TAR vượt quá dung lượng khai báo."; break;
            }
            // Preserve sparse ranges supplied by libarchive; also omit zero blocks.
            const auto *p = static_cast<const unsigned char *>(buffer);
            size_t written = 0;
            while (written < bytes) {
                size_t chunk = std::min(size_t{65536}, bytes-written);
                if (disk && std::all_of(p+written,p+written+chunk,[](unsigned char b){return b==0;})) {
                    written += chunk; continue;
                }
                ssize_t n = pwrite(fd,p+written,chunk,(off_t)(offset+written));
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) { problem = [NSString stringWithFormat:@"Ghi ROM thất bại: %s",strerror(errno)]; break; }
                written += (size_t)n;
            }
            if (problem) break;
        }
        if (!problem && rc != ARCHIVE_EOF) problem = @"Dữ liệu TAR bị thiếu hoặc lỗi.";
        if (!problem && ftruncate(fd,(off_t)size) != 0) problem = @"Không đặt được dung lượng ảnh đĩa.";
        if (close(fd) != 0 && !problem) problem = @"Không đóng được tệp ROM.";
    }
    if (!problem && result != ARCHIVE_EOF) problem = [NSString stringWithFormat:@"TAR lỗi: %s",archive_error_string(reader) ?: "unknown"];
    if (!problem && seen != wanted) problem = @"Gói ROM không đủ bốn tệp cần thiết (r29).";
    archive_read_free(reader);
    return problem;
}
