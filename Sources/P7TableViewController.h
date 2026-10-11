#import <UIKit/UIKit.h>
#import "P7Models.h"
#import "P7TrackCell.h"

// The text for a list that failed to load; only network failures blame the server.
NSString *P7ErrorMessage(NSError *error);

// Base for every list screen: "Now Playing" button, loading / empty / error
// state, live refresh of track rows (playing, offline, download progress)
// and the "…" action sheet for a track.
@interface P7TableViewController : UITableViewController

- (void)reload;   // subclasses load their data here; also bound to pull-to-refresh and "Try Again"
- (void)enablePullToRefresh;
- (void)endRefreshing;

- (void)showLoading;
- (void)showMessage:(NSString *)message retry:(BOOL)retry;
- (void)hideMessage;

- (P7TrackCell *)trackCellForTrack:(P7Track *)track number:(NSInteger)number;
- (void)showActionsForTrack:(P7Track *)track;
- (void)playTracks:(NSArray *)tracks startIndex:(NSInteger)index;
- (void)presentNowPlaying;

// Called when downloads or the current track change; default refreshes visible track rows.
- (void)trackStatesDidChange;
- (void)refreshVisibleTrackCells;

@end
