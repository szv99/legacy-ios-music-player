#import "P7TableViewController.h"

// Separate searches for Spotify, YouTube Music and your own songs, switched in the
// navigation bar. Each source keeps its results; tapping one streams it through the server.
@interface P7SearchViewController : P7TableViewController
- (void)searchFor:(NSString *)query source:(NSInteger)source;   // 0 Spotify, 1 YouTube, 2 SoundCloud, 3 Library
@end
