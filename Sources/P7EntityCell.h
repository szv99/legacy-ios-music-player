#import <UIKit/UIKit.h>
#import "P7Models.h"

// Row for an artist (round picture), album or playlist; same metrics as P7TrackCell
// so it sits between song rows in search results and on artist pages.
@interface P7EntityCell : UITableViewCell
+ (CGFloat)rowHeight;
- (void)configureWithEntity:(P7Entity *)entity;
// Plain "All Songs ›" style row without a picture.
- (void)configureWithTitle:(NSString *)title;
@end
