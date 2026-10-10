#import <AVFoundation/AVFoundation.h>

// Live spectrum of what's playing, for the Encore lock screen visualizer.
// An audio processing tap on the player item measures 7 frequency bands; they are
// published ~30 times a second as the notify(3) state of "com.szv.encore.levels":
// bits 0-55 hold the bands (8 bits each, low to high), bits 56-63 a frame counter
// so readers can tell fresh values from a stale state.
@interface P7AudioLevels : NSObject
+ (void)attachToPlayerItem:(AVPlayerItem *)item;   // call once the item is ready to play
+ (void)publishSilence;
@end
