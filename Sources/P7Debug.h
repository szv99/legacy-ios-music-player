#import <UIKit/UIKit.h>

// Development hooks driven by player7:// URLs (see dev.sh):
//   player7://screenshot          render the window to /tmp/player7-screenshot.png
//   player7://server/<host:port>  point the app at a Player7 server (and select it as the source)
//   player7://token/<token>       set the server token
//   player7://backend/<n>         music source: 0 This iPhone, 1 Player7 server, 2 Subsonic
//   player7://subsonic?url=…&user=…&password=…   use a Subsonic server
//   player7://import?url=<link>   import a playlist / album / artist link
//   player7://clearsongs          empty the on-phone song cache
//   player7://tab/<n>             select a tab
//   player7://select/<row>        tap a row in the visible list
//   player7://back                pop the visible navigation stack
//   player7://dismiss             dismiss the presented screen
//   player7://nowplaying          open Now Playing
//   player7://queue               open Up Next
//   player7://play                play the whole library
//   player7://search/<src>/<q>    search (src 0 Spotify, 1 YouTube Music, 2 SoundCloud, 3 Library, 4 Subsonic, 5 YouTube videos)
//   player7://probe?url=<link>    log whether AVPlayer can open an audio URL, and the error if not
@interface P7Debug : NSObject
+ (BOOL)handleURL:(NSURL *)url window:(UIWindow *)window;
@end
