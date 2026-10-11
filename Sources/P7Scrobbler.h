#import <UIKit/UIKit.h>
#import "P7Models.h"

extern NSString *const P7LastFMDidChangeNotification;   // account, setting or queue changed

// Last.fm scrobbling, straight from the phone with every music source (see P7LastFM).
// Follows the player: "now playing" when a song starts, a scrobble once half of it
// (or 4 minutes) has really been heard. Plays made offline wait in a queue on the phone.
@interface P7Scrobbler : NSObject
+ (instancetype)shared;
- (void)start;

@property (nonatomic, readonly) BOOL configured;     // this build has a Last.fm API key
@property (nonatomic, readonly) BOOL connected;      // a Last.fm account is linked
@property (nonatomic, readonly, copy) NSString *username;
@property (nonatomic) BOOL enabled;                  // "Scrobble" switch, default on
@property (nonatomic, readonly) NSUInteger pendingCount;

- (void)connectFrom:(UIViewController *)controller;
- (void)disconnect;
- (void)loveTrack:(P7Track *)track;
- (void)flush;
@end
