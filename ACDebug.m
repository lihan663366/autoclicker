//
//  ACDebug.m
//

#import "ACDebug.h"
#import <UIKit/UIKit.h>

static NSString *sLogPath = nil;
static dispatch_queue_t sLogQueue = nil;

static NSString *ACDResolveLogPath(void) {
    // rootless 越狱下 /var/jb 是符号链接根，但 /var/mobile 是真实路径，两边都能写。
    NSArray *dirs = @[@"/var/mobile/Library/Logs",
                      @"/var/mobile/Documents",
                      NSTemporaryDirectory()];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *d in dirs) {
        if (!d) continue;
        if (![fm fileExistsAtPath:d]) {
            [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
        }
        if (![fm isWritableFileAtPath:d]) continue;
        return [d stringByAppendingPathComponent:@"AutoClicker.log"];
    }
    return nil;
}

NSString *ACDLogPath(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sLogQueue = dispatch_queue_create("com.acme.autoclicker.log", DISPATCH_QUEUE_SERIAL);
        sLogPath = ACDResolveLogPath();
    });
    return sLogPath;
}

void ACDLog(NSString *fmt, ...) {
    if (!fmt) return;

    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    static NSDateFormatter *df = nil;
    static dispatch_once_t onceTok;
    dispatch_once(&onceTok, ^{
        df = [NSDateFormatter new];
        df.dateFormat = @"HH:mm:ss.SSS";
    });

    NSString *proc = [NSProcessInfo processInfo].processName ?: @"?";
    NSString *line = [NSString stringWithFormat:@"[%@] %@/%@  %@\n",
                      [df stringFromDate:[NSDate date]], proc,
                      [@(getpid()) stringValue], body];

    // 同时打到系统日志，Console.app 里也能看到
    NSLog(@"[AutoClicker] %@", body);

    NSString *path = ACDLogPath();
    if (!path) return;

    dispatch_async(sLogQueue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            return;
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) return;
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (__unused NSException *e) { }
    });
}

NSString *ACDLogTail(NSUInteger lines) {
    NSString *path = ACDLogPath();
    if (!path) return @"（日志文件不可写）";
    NSString *all = [NSString stringWithContentsOfFile:path
                                             encoding:NSUTF8StringEncoding
                                                error:NULL];
    if (!all.length) return @"（日志为空）";
    NSArray *arr = [all componentsSeparatedByString:@"\n"];
    if (arr.count <= lines) return all;
    return [[arr subarrayWithRange:NSMakeRange(arr.count - lines, lines)]
            componentsJoinedByString:@"\n"];
}
