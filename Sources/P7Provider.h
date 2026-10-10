#import <Foundation/Foundation.h>

// A music source that runs inside the app. P7LocalServer serves the same /api/* routes as
// the Player7 server (see P7API.h) on 127.0.0.1 and hands each request to the provider of
// the selected backend, so the rest of the app works the same with every backend.
//
// All methods are called on background threads, possibly several at once, and may block
// on the network. Failures return nil and set *error; use P7ProviderError() so the
// message reaches the user and the code becomes the HTTP status.
@protocol P7Provider <NSObject>

// The JSON answer (NSDictionary / NSArray) for /api/<parts...>, e.g. parts @[@"playlists", @"sp-pl-1"].
// method: "GET", "HEAD" or "POST". query: decoded URL parameters. body: decoded JSON body of a POST (or @{}).
// The audio and cover routes (/api/tracks/<id>/stream and /cover) never get here.
- (id)responseForMethod:(NSString *)method parts:(NSArray *)parts query:(NSDictionary *)query body:(NSDictionary *)body error:(NSError **)error;

// Where the track's audio can be fetched right now. http:// URLs are handed to the player as a
// redirect; https:// URLs are relayed by the local server (so the bundled root certificates
// apply) with these extra request headers (may be nil).
- (NSURL *)audioURLForTrackID:(NSString *)trackID headers:(NSDictionary **)headers error:(NSError **)error;

// The original picture for a track, artist, album or playlist id, or for "<id>-banner".
// The local server downloads it and crops / scales it like the Player7 server does.
- (NSURL *)imageURLForID:(NSString *)itemID size:(NSInteger)size error:(NSError **)error;

@optional
// Called when the audio relay got 403/404/410 from audioURL, so a cached stream URL can be dropped.
- (void)audioURLFailedForTrackID:(NSString *)trackID;

@end

NSError *P7ProviderError(NSInteger status, NSString *message);
