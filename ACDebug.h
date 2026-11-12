//
//  ACDebug.h — 落盘日志
//
//  越狱环境下没法连调试器，出问题只能靠日志定位。
//  日志写到 /var/mobile/Library/Logs/AutoClicker.log，用 Filza 或 SSH 就能看。
//

#import <Foundation/Foundation.h>

/// 写一行日志（自动带时间戳和进程名）。任意线程可调。
void ACDLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

/// 日志文件完整路径，面板上显示用
NSString *ACDLogPath(void);

/// 最近 N 行日志，直接贴给我就能定位问题
NSString *ACDLogTail(NSUInteger lines);
