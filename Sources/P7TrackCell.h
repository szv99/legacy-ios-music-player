#import <UIKit/UIKit.h>
#import "P7Models.h"

typedef NS_ENUM(NSInteger, P7TrackCellStyle) {
	P7TrackCellStyleArtwork,   // cover thumbnail on the left (playlists, library)
	P7TrackCellStyleNumbered,  // position number instead of artwork (queue)
};

// Song row: artwork or number, title, "artist · duration", offline state and a "…" button.
// Highlights the row that is currently playing.
@interface P7TrackCell : UITableViewCell
@property (nonatomic) P7TrackCellStyle style;
@property (nonatomic, copy) void (^moreHandler)(P7TrackCell *cell);
+ (CGFloat)rowHeight;
- (void)configureWithTrack:(P7Track *)track number:(NSInteger)number;
- (void)refreshState;
@end
