#import <Foundation/Foundation.h>
#import "P7Models.h"

typedef NS_ENUM(NSInteger, P7RepeatMode) {
	P7RepeatOff,
	P7RepeatAll,
	P7RepeatOne,
};

extern NSString *const P7PlayerDidChangeNotification;   // track, play state, queue, shuffle or repeat changed
extern NSString *const P7PlayerProgressNotification;    // periodic while playing

// Playback engine: queue management on top of AVPlayer, background audio,
// lock screen info and remote controls. Plays the offline copy when one exists.
@interface P7Player : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) NSArray *queue;            // P7Track in play order
@property (nonatomic, readonly) NSInteger currentIndex;    // NSNotFound when idle
@property (nonatomic, readonly) P7Track *currentTrack;
@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, readonly) BOOL isBuffering;
@property (nonatomic, readonly) NSTimeInterval currentTime;
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic) BOOL shuffle;
@property (nonatomic) P7RepeatMode repeatMode;

// Sleep timer: pause after a while (fading out) or when the current song ends.
@property (nonatomic, readonly) NSDate *sleepDate;          // nil when off or set to end of song
@property (nonatomic, readonly) BOOL sleepAtEndOfTrack;
- (void)sleepAfter:(NSTimeInterval)seconds;                 // 0 turns the timer off
- (void)sleepAtEndOfCurrentTrack;

- (void)setUp;
- (void)saveState;

- (void)playTracks:(NSArray *)tracks startIndex:(NSInteger)index;
- (void)shuffleTracks:(NSArray *)tracks;
- (void)playQueueIndex:(NSInteger)index;
- (void)playNext:(NSArray *)tracks;
- (void)addToQueue:(NSArray *)tracks;
- (void)removeQueueIndex:(NSInteger)index;
- (void)moveQueueIndex:(NSInteger)from toIndex:(NSInteger)to;

- (void)play;
- (void)pause;
- (void)togglePlayPause;
- (void)next;
- (void)previous;
- (void)seekToTime:(NSTimeInterval)time;

@end
