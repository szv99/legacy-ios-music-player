#import <Foundation/Foundation.h>

// Last.fm straight from the phone, whatever the music source (used by P7Scrobbler).
// The user logs in once with their Last.fm username and password (auth.getMobileSession,
// sent only to Last.fm); the session key is kept in the keychain.
// The API key and secret come from the build (LASTFM_API_KEY and LASTFM_API_SECRET, see the
// Makefile). Without them, there's no scrobbling.
@interface P7LastFM : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL available;   // this build has an API key

// Blocking, so not on the main thread except for the status. action: nil for the status
// {configured, connected, username}, or connect, disconnect, nowplaying, scrobble, love.
- (NSDictionary *)responseForAction:(NSString *)action body:(NSDictionary *)body error:(NSError **)error;
@end
