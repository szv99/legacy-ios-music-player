#import "P7MiniPlayer.h"
#import "P7Player.h"
#import "P7Theme.h"
#import "P7ImageCache.h"
#import "P7FadeImageView.h"
#import "P7NowPlayingViewController.h"

NSString *const P7MiniPlayerDidChangeNotification = @"P7MiniPlayerDidChangeNotification";

static const CGFloat kHeight = 50;
static P7MiniPlayer *sShared;

@implementation P7MiniPlayer {
	__weak UITabBarController *_tabBarController;
	UIToolbar *_background;     // UIToolbar gives the live iOS 7 blur
	UIView *_progress;
	P7FadeImageView *_artworkView;
	UILabel *_titleLabel;
	UILabel *_artistLabel;
	UIButton *_playButton;
	UIButton *_nextButton;
	UIActivityIndicatorView *_bufferingView;
	NSString *_shownTrackID;
	BOOL _shown;
}

+ (instancetype)attachToTabBarController:(UITabBarController *)tabBarController {
	P7MiniPlayer *bar = [[P7MiniPlayer alloc] initWithFrame:CGRectZero];
	bar->_tabBarController = tabBarController;
	[tabBarController.view insertSubview:bar belowSubview:tabBarController.tabBar];
	sShared = bar;
	[bar update];
	return bar;
}

+ (CGFloat)visibleHeight {
	return sShared && sShared->_shown ? kHeight : 0;
}

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.clipsToBounds = YES;
		_background = [[UIToolbar alloc] initWithFrame:self.bounds];
		_background.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		[self addSubview:_background];

		_progress = [UIView new];
		_progress.backgroundColor = [P7Theme tintColor];
		[self addSubview:_progress];

		_artworkView = [P7FadeImageView new];
		_artworkView.contentMode = UIViewContentModeScaleAspectFill;
		_artworkView.clipsToBounds = YES;
		_artworkView.layer.cornerRadius = 2;
		[self addSubview:_artworkView];

		_titleLabel = [UILabel new];
		_titleLabel.font = [UIFont systemFontOfSize:15];
		[self addSubview:_titleLabel];
		_artistLabel = [UILabel new];
		_artistLabel.font = [UIFont systemFontOfSize:12];
		_artistLabel.textColor = [P7Theme secondaryTextColor];
		[self addSubview:_artistLabel];

		_playButton = [UIButton buttonWithType:UIButtonTypeSystem];
		_playButton.tintColor = [UIColor colorWithWhite:0.1 alpha:1];
		[_playButton addTarget:self action:@selector(togglePlay) forControlEvents:UIControlEventTouchUpInside];
		[self addSubview:_playButton];
		_nextButton = [UIButton buttonWithType:UIButtonTypeSystem];
		_nextButton.tintColor = [UIColor colorWithWhite:0.1 alpha:1];
		[_nextButton setImage:[P7Theme smallNextIcon] forState:UIControlStateNormal];
		[_nextButton addTarget:self action:@selector(next) forControlEvents:UIControlEventTouchUpInside];
		[self addSubview:_nextButton];
		_bufferingView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
		_bufferingView.hidesWhenStopped = YES;
		[self addSubview:_bufferingView];

		[self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(open)]];
		UISwipeGestureRecognizer *up = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(open)];
		up.direction = UISwipeGestureRecognizerDirectionUp;
		[self addGestureRecognizer:up];
		UISwipeGestureRecognizer *left = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(next)];
		left.direction = UISwipeGestureRecognizerDirectionLeft;
		[self addGestureRecognizer:left];
		UISwipeGestureRecognizer *right = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(previous)];
		right.direction = UISwipeGestureRecognizerDirectionRight;
		[self addGestureRecognizer:right];

		NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
		[nc addObserver:self selector:@selector(update) name:P7PlayerDidChangeNotification object:nil];
		[nc addObserver:self selector:@selector(updateProgress) name:P7PlayerProgressNotification object:nil];
	}
	return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Layout

// Sits on the tab bar while shown, tucked behind it while hidden.
- (CGRect)frameShown:(BOOL)shown {
	CGRect tabBar = _tabBarController.tabBar.frame;
	CGFloat y = shown ? CGRectGetMinY(tabBar) - kHeight : CGRectGetMinY(tabBar);
	return CGRectMake(0, y, tabBar.size.width, kHeight);
}

- (void)layoutSubviews {
	[super layoutSubviews];
	CGFloat width = self.bounds.size.width;
	_artworkView.frame = CGRectMake(8, 7, 36, 36);
	_nextButton.frame = CGRectMake(width - 46, 3, 44, 44);
	_playButton.frame = CGRectMake(width - 90, 3, 44, 44);
	_bufferingView.center = _playButton.center;
	CGFloat x = 54, textWidth = width - 90 - x - 4;
	_titleLabel.frame = CGRectMake(x, 8, textWidth, 18);
	_artistLabel.frame = CGRectMake(x, 26, textWidth, 16);
	[self updateProgress];
}

- (void)didMoveToSuperview {
	[super didMoveToSuperview];
	self.frame = [self frameShown:_shown];
	self.hidden = !_shown;
}

#pragma mark - Updating

- (void)update {
	P7Player *player = [P7Player shared];
	P7Track *track = player.currentTrack;
	[self setShown:track != nil];
	if (!track) return;
	if (![_shownTrackID isEqualToString:track.trackID]) {
		BOOL first = _shownTrackID == nil;
		_shownTrackID = track.trackID;
		if (!first) {
			CATransition *push = [CATransition animation];
			push.type = kCATransitionFade;
			push.duration = 0.25;
			[_titleLabel.layer addAnimation:push forKey:@"fade"];
			[_artistLabel.layer addAnimation:push forKey:@"fade"];
		}
		[_artworkView p7_setCoverForTrackID:track.coverKey size:72 placeholder:[P7Theme placeholderArtworkWithSize:36]];
	}
	_titleLabel.text = track.title;
	_artistLabel.text = track.artist;
	BOOL buffering = player.isBuffering;
	_playButton.hidden = buffering;
	buffering ? [_bufferingView startAnimating] : [_bufferingView stopAnimating];
	[_playButton setImage:player.isPlaying ? [P7Theme smallPauseIcon] : [P7Theme smallPlayIcon] forState:UIControlStateNormal];
	[self updateProgress];
}

- (void)updateProgress {
	P7Player *player = [P7Player shared];
	NSTimeInterval duration = player.duration;
	CGFloat fraction = duration > 0 ? MAX(0, MIN(1, player.currentTime / duration)) : 0;
	_progress.frame = CGRectMake(0, 0, roundf(self.bounds.size.width * fraction), 2);
}

- (void)setShown:(BOOL)shown {
	if (_shown == shown) {
		self.frame = [self frameShown:shown];   // follows the tab bar (e.g. in-call status bar)
		self.hidden = !shown;
		return;
	}
	_shown = shown;
	// Hidden behind the translucent tab bar it would still blur through, so it's also hidden.
	self.hidden = NO;
	[UIView animateWithDuration:self.window ? 0.45 : 0 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.3 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
		self.frame = [self frameShown:shown];
	} completion:^(BOOL finished) {
		if (!self->_shown) self.hidden = YES;
	}];
	[[NSNotificationCenter defaultCenter] postNotificationName:P7MiniPlayerDidChangeNotification object:self];
}

#pragma mark - Actions

- (void)togglePlay {
	[[P7Player shared] togglePlayPause];
}

- (void)next {
	[[P7Player shared] next];
}

- (void)previous {
	[[P7Player shared] previous];
}

- (void)open {
	UITabBarController *tabs = _tabBarController;
	if (!tabs || tabs.presentedViewController) return;
	[tabs presentViewController:[P7NowPlayingViewController new] animated:YES completion:nil];
}

@end

@implementation UIViewController (P7MiniPlayer)

- (void)p7_adjustInsetsForMiniPlayer:(UIScrollView *)scrollView {
	UITabBar *tabBar = self.tabBarController.tabBar;
	if (!tabBar || self.presentingViewController) return;
	// Not bottomLayoutGuide: on iOS 7 asking a table view controller for it adds Auto Layout
	// guides to the table, which then loses its content size and can't be scrolled.
	CGFloat bottom = (tabBar.hidden ? 0 : tabBar.frame.size.height) + [P7MiniPlayer visibleHeight];
	UIEdgeInsets insets = scrollView.contentInset;
	if (insets.bottom == bottom) return;
	insets.bottom = bottom;
	scrollView.contentInset = insets;
	UIEdgeInsets indicators = scrollView.scrollIndicatorInsets;
	indicators.bottom = bottom;
	scrollView.scrollIndicatorInsets = indicators;
}

@end
