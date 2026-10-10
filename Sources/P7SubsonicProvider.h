#import <Foundation/Foundation.h>
#import "P7Provider.h"

// Navidrome, Airsonic, Gonic or any other Subsonic-compatible server, as a P7Provider.
//
// Ids: songs "ss-<id>", albums "ss-al-<id>", artists "ss-ar-<id>", playlists "ss-pl-<id>".
// The library is what's starred on the server (plus the user's playlists): "Add to Library"
// stars an album or artist, the heart on a song stars the song. Scrobbles go to the server
// (scrobble.view), which passes them on to Last.fm / ListenBrainz if it is set up to.
// Songs in formats iOS 7 can't play (FLAC, Ogg, Opus, ...) are transcoded to MP3 by the server.
@interface P7SubsonicProvider : NSObject <P7Provider>
@end
