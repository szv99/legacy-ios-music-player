#import "P7TableViewController.h"
#import "P7NowPlayingViewController.h"
#import "P7Player.h"
#import "P7Downloads.h"
#import "P7Blocks.h"
#import "P7Theme.h"
#import "P7API.h"
#import "P7EqualizerView.h"
#import "P7ImageCache.h"
#import "P7Navigator.h"
#import "P7MiniPlayer.h"

static NSString *const kTrackCell = @"P7TrackCell";

@implementation P7TableViewController {
	P7EqualizerView *_nowPlayingBars;
	UIView *_messageView;
	UILabel *_messageLabel;
	UIButton *_retryButton;
	UIActivityIndicatorView *_spinner;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.tableView.rowHeight = [P7TrackCell rowHeight];
	[self.tableView registerClass:[P7TrackCell class] forCellReuseIdentifier:kTrackCell];

	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc addObserver:self selector:@selector(playerDidChange) name:P7PlayerDidChangeNotification object:nil];
	[nc addObserver:self selector:@selector(trackStatesDidChange) name:P7DownloadsDidChangeNotification object:nil];
	[nc addObserver:self selector:@selector(downloadProgress:) name:P7DownloadProgressNotification object:nil];
	[nc addObserver:self.tableView selector:@selector(reloadData) name:P7ImageCacheDidClearNotification object:nil];
	[nc addObserver:self.view selector:@selector(setNeedsLayout) name:P7MiniPlayerDidChangeNotification object:nil];
	[self updateNowPlayingButton];
}

NSString *P7ErrorMessage(NSError *error) {
	if ([error.domain isEqualToString:NSURLErrorDomain]) return [NSString stringWithFormat:@"Can't reach the server.\n%@", error.localizedDescription];
	return error.localizedDescription ?: @"Something went wrong.";
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[[NSNotificationCenter defaultCenter] removeObserver:self.tableView];
	[[NSNotificationCenter defaultCenter] removeObserver:self.view];
}

- (void)reload {
}

#pragma mark - Pull to refresh

- (void)enablePullToRefresh {
	self.refreshControl = [UIRefreshControl new];
	[self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
}

- (void)endRefreshing {
	[self.refreshControl endRefreshing];
}

#pragma mark - Now Playing button

- (void)playerDidChange {
	[self updateNowPlayingButton];
	[self trackStatesDidChange];
}

- (void)updateNowPlayingButton {
	P7Player *player = [P7Player shared];
	if (!player.currentTrack) {
		self.navigationItem.rightBarButtonItem = nil;
		_nowPlayingBars = nil;
		return;
	}
	if (!_nowPlayingBars) {
		UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
		button.frame = CGRectMake(0, 0, 36, 32);
		button.accessibilityLabel = @"Now Playing";
		[button addTarget:self action:@selector(presentNowPlaying) forControlEvents:UIControlEventTouchUpInside];
		_nowPlayingBars = [[P7EqualizerView alloc] initWithFrame:CGRectMake(12, 8, 17, 15)];
		[button addSubview:_nowPlayingBars];
		self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:button];
	}
	_nowPlayingBars.animating = player.isPlaying && !player.isBuffering;
}

- (void)presentNowPlaying {
	P7NowPlayingViewController *controller = [P7NowPlayingViewController new];
	[(self.tabBarController ?: self) presentViewController:controller animated:YES completion:nil];
}

#pragma mark - State view

- (void)ensureMessageView {
	if (_messageView) return;
	_messageView = [[UIView alloc] initWithFrame:self.tableView.bounds];
	_messageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

	_messageLabel = [UILabel new];
	_messageLabel.numberOfLines = 0;
	_messageLabel.textAlignment = NSTextAlignmentCenter;
	_messageLabel.textColor = [P7Theme secondaryTextColor];
	_messageLabel.font = [UIFont systemFontOfSize:17];
	[_messageView addSubview:_messageLabel];

	_retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
	_retryButton.titleLabel.font = [UIFont systemFontOfSize:17];
	[_retryButton setTitle:@"Try Again" forState:UIControlStateNormal];
	[_retryButton addTarget:self action:@selector(reload) forControlEvents:UIControlEventTouchUpInside];
	[_messageView addSubview:_retryButton];

	_spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
	[_messageView addSubview:_spinner];
}

- (void)layoutMessageView {
	CGFloat width = self.tableView.bounds.size.width;
	CGFloat top = self.tableView.contentInset.top + self.tableView.tableHeaderView.frame.size.height;
	CGFloat visible = self.tableView.bounds.size.height - self.tableView.contentInset.top - self.tableView.contentInset.bottom;
	CGFloat center = top + MAX(80, (visible - self.tableView.tableHeaderView.frame.size.height) / 2) - 20;
	CGSize size = [_messageLabel sizeThatFits:CGSizeMake(width - 60, CGFLOAT_MAX)];
	_messageLabel.frame = CGRectMake(30, center - size.height / 2, width - 60, size.height);
	_retryButton.frame = CGRectMake(0, CGRectGetMaxY(_messageLabel.frame) + 12, width, 30);
	_spinner.center = CGPointMake(width / 2, center);
}

- (void)showLoading {
	[self ensureMessageView];
	_messageLabel.hidden = YES;
	_retryButton.hidden = YES;
	[_spinner startAnimating];
	self.tableView.backgroundView = _messageView;
	self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
	[self layoutMessageView];
}

- (void)showMessage:(NSString *)message retry:(BOOL)retry {
	[self ensureMessageView];
	[_spinner stopAnimating];
	_messageLabel.hidden = NO;
	_messageLabel.text = message;
	_retryButton.hidden = !retry;
	self.tableView.backgroundView = _messageView;
	self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
	[self layoutMessageView];
}

- (void)hideMessage {
	[_spinner stopAnimating];
	self.tableView.backgroundView = nil;
	self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
}

- (void)viewDidLayoutSubviews {
	[super viewDidLayoutSubviews];
	[self p7_adjustInsetsForMiniPlayer:self.tableView];
	if (_messageView.superview) [self layoutMessageView];
}

#pragma mark - Tracks

- (P7TrackCell *)trackCellForTrack:(P7Track *)track number:(NSInteger)number {
	P7TrackCell *cell = [self.tableView dequeueReusableCellWithIdentifier:kTrackCell];
	cell.style = P7TrackCellStyleArtwork;
	[cell configureWithTrack:track number:number];
	__weak P7TableViewController *weakSelf = self;
	cell.moreHandler = ^(P7TrackCell *c) { [weakSelf showActionsForTrack:track]; };
	return cell;
}

- (void)trackStatesDidChange {
	[self refreshVisibleTrackCells];
}

- (void)refreshVisibleTrackCells {
	for (UITableViewCell *cell in self.tableView.visibleCells) {
		if ([cell isKindOfClass:[P7TrackCell class]]) [(P7TrackCell *)cell refreshState];
	}
}

- (void)downloadProgress:(NSNotification *)note {
	[self refreshVisibleTrackCells];
}

- (void)playTracks:(NSArray *)tracks startIndex:(NSInteger)index {
	P7Track *track = tracks[index];
	if (!track.available && ![[P7Downloads shared] isDownloaded:track.trackID]) {
		[P7Alert showMessage:@"This song hasn't been downloaded to the server yet." title:track.title];
		return;
	}
	[[P7Player shared] playTracks:tracks startIndex:index];
}

- (void)showActionsForTrack:(P7Track *)track {
	P7ActionSheet *sheet = [[P7ActionSheet alloc] initWithTitle:[NSString stringWithFormat:@"%@\n%@", track.title, track.artist]];
	P7Player *player = [P7Player shared];
	P7Downloads *downloads = [P7Downloads shared];
	[sheet addButton:@"Play Next" handler:^{ [player playNext:@[track]]; }];
	[sheet addButton:@"Add to Up Next" handler:^{ [player addToQueue:@[track]]; }];
	if ([track.trackID hasPrefix:@"sp-"] || [track.trackID hasPrefix:@"yt-"] || [track.trackID hasPrefix:@"sc-"] || [track.trackID hasPrefix:@"ss-"]) {
		[sheet addButton:@"Go to Artist" handler:^{ [P7Navigator openArtistOfTrack:track from:self]; }];
	}
	if (track.albumID) {
		[sheet addButton:@"Go to Album" handler:^{ [P7Navigator openAlbumOfTrack:track from:self]; }];
	}
	BOOL inLibrary = [[P7API shared] isTrackInLibrary:track];
	[sheet addButton:inLibrary ? @"Remove from Songs" : @"Add to Songs" handler:^{
		[[P7API shared] setTrack:track inLibrary:!inLibrary completion:^(NSError *error) {
			if (error) [P7Alert showError:error title:inLibrary ? @"Couldn't Remove" : @"Couldn't Add"];
		}];
	}];
	if ([downloads isDownloaded:track.trackID]) {
		[sheet addDestructiveButton:@"Remove Download" handler:^{ [downloads removeTrackID:track.trackID]; }];
	} else if ([downloads isDownloading:track.trackID]) {
		[sheet addDestructiveButton:@"Cancel Download" handler:^{ [downloads removeTrackID:track.trackID]; }];
	} else if (track.available) {
		[sheet addButton:@"Download" handler:^{ [downloads downloadTracks:@[track]]; }];
	}
	[sheet showFrom:self];
}

@end
