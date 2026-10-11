#import <Foundation/Foundation.h>
#import "P7Provider.h"

// A small HTTP server on 127.0.0.1 that answers the Player7 server's /api/* routes inside
// the app, using the provider of the selected backend ("This iPhone" or Subsonic). It also
// plays YouTube for the Player7 server backend, and YouTube and Subsonic songs left in the
// queue after switching sources. The player, song cache, downloads and image cache keep
// loading plain http:// URLs and don't need to know which backend is in use.
//
//   /api/tracks/<id>/stream   http:// sources are redirected to; https:// sources are relayed
//                             in chunks (Range supported) so the bundled root certificates
//                             apply, and an expired stream URL is looked up again mid-song.
//   /api/tracks/<id>/cover    the provider's picture, cropped square and scaled to ?size=
//   everything else           JSON from -[P7Provider responseForMethod:...]
//
// Only reachable from this iPhone, and every request must carry ?token=<token>.
@interface P7LocalServer : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) NSString *baseURL;   // starts the server if needed; nil if no port could be opened
@property (nonatomic, readonly) NSString *token;     // random, kept across launches (background downloads outlive the app)

// iOS may take the listening socket away while the app is suspended; reopen it if so.
- (void)restartIfNeeded;

@end
