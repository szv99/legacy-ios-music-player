#import <Foundation/Foundation.h>

// Shares Up Next with the Encore lock screen tweak (SpringBoard).
//  - writes /var/mobile/Library/Player7Lock/queue.plist plus small cover JPEGs and posts
//    "com.szv.player7.queue" whenever the queue or the current song changes
//  - runs the lock screen's requests (play / move / remove a queue position) from
//    commands.plist in the same folder, on "com.szv.player7.lockcommand"; after a pause
//    the app stays awake a few minutes so they apply right away
@interface P7LockQueue : NSObject
+ (void)start;
@end
