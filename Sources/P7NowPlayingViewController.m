#import "P7NowPlayingViewController.h"
#import "P7TrackCell.h"
#import "P7Player.h"
#import "P7ImageCache.h"
#import "P7FadeImageView.h"
#import "P7ArtworkEffects.h"
#import "P7Theme.h"
#import "P7Navigator.h"
#import "P7Downloads.h"
#import "P7Blocks.h"
#import "P7API.h"
#import "P7Scrobbler.h"
#import <MediaPlayer/MediaPlayer.h>

@implementation P7NowPlayingViewController {
	P7FadeImageView *_backgroundView;   // blurred cover behind everything
	UIView *_backgroundTint;
	UIButton *_closeButton;
	UIButton *_queueButton;
	UILabel *_positionLabel;
	UIView *_artworkContainer;          // carries the shadow, scale and parallax
	P7FadeImageView *_artworkView;
	UISlider *_scrubber;
	UILabel *_elapsedLabel;
	UILabel *_remainingLabel;
	UILabel *_titleLabel;
	UILabel *_artistLabel;
	UIButton *_previousButton;
	UIButton *_playButton;
	UIButton *_nextButton;
	MPVolumeView *_volumeView;
	UIButton *_repeatButton;
	UIButton *_shuffleButton;
	UIButton *_moreButton;
	UIActivityIndicatorView *_bufferingView;
	NSTimer *_clock;                    // counts the sleep timer down, also while paused
	UIColor *_accent;
	BOOL _scrubbing;
	BOOL _shownPlaying;
	NSString *_shownTrackID;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = [UIColor whiteColor];
	self.view.clipsToBounds = YES;
	_accent = [P7Theme tintColor];
	UIColor *dark = [UIColor colorWithWhite:0.1 alpha:1];

	_backgroundView = [[P7FadeImageView alloc] initWithFrame:CGRectInset(self.view.bounds, -40, -40)];
	_backgroundView.fadeDuration = 0.6;
	_backgroundView.contentMode = UIViewContentModeScaleAspectFill;
	_backgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	[self.view addSubview:_backgroundView];
	_backgroundTint = [[UIView alloc] initWithFrame:self.view.bounds];
	_backgroundTint.backgroundColor = [UIColor colorWithWhite:1 alpha:0.72];
	_backgroundTint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	[self.view addSubview:_backgroundTint];
	[self addParallaxTo:_backgroundView amount:-18];

	_closeButton = [self iconButton:[P7Theme chevronDownIcon] action:@selector(close)];
	_closeButton.tintColor = dark;
	_queueButton = [self iconButton:[P7Theme queueIcon] action:@selector(showQueue)];
	_queueButton.tintColor = dark;

	_positionLabel = [self labelWithFont:[UIFont systemFontOfSize:12] color:[UIColor colorWithWhite:0 alpha:0.45]];
	_positionLabel.textAlignment = NSTextAlignmentCenter;

	_artworkContainer = [UIView new];
	_artworkContainer.layer.shadowColor = [UIColor blackColor].CGColor;
	_artworkContainer.layer.shadowOpacity = 0.28;
	_artworkContainer.layer.shadowRadius = 14;
	_artworkContainer.layer.shadowOffset = CGSizeMake(0, 8);
	[self.view addSubview:_artworkContainer];
	_artworkView = [P7FadeImageView new];
	_artworkView.fadeDuration = 0.35;
	_artworkView.contentMode = UIViewContentModeScaleAspectFill;
	_artworkView.clipsToBounds = YES;
	_artworkView.userInteractionEnabled = YES;
	_artworkView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	[_artworkContainer addSubview:_artworkView];
	[self addParallaxTo:_artworkContainer amount:12];
	__weak P7NowPlayingViewController *weakSelf = self;
	_artworkView.imageDidChange = ^(UIImage *image) { [weakSelf artworkChanged:image]; };

	UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(close)];
	swipe.direction = UISwipeGestureRecognizerDirectionDown;
	[self.view addGestureRecognizer:swipe];
	UISwipeGestureRecognizer *swipeLeft = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipedArtworkLeft)];
	swipeLeft.direction = UISwipeGestureRecognizerDirectionLeft;
	[_artworkView addGestureRecognizer:swipeLeft];
	UISwipeGestureRecognizer *swipeRight = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipedArtworkRight)];
	swipeRight.direction = UISwipeGestureRecognizerDirectionRight;
	[_artworkView addGestureRecognizer:swipeRight];
	UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(togglePlay)];
	[_artworkView addGestureRecognizer:tap];

	_scrubber = [UISlider new];
	_scrubber.maximumTrackTintColor = [UIColor colorWithWhite:0 alpha:0.15];
	[_scrubber addTarget:self action:@selector(scrubStarted) forControlEvents:UIControlEventTouchDown];
	[_scrubber addTarget:self action:@selector(scrubMoved) forControlEvents:UIControlEventValueChanged];
	[_scrubber addTarget:self action:@selector(scrubEnded) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
	[self.view addSubview:_scrubber];

	UIColor *timeColor = [UIColor colorWithWhite:0 alpha:0.5];
	_elapsedLabel = [self labelWithFont:[UIFont systemFontOfSize:11] color:timeColor];
	_remainingLabel = [self labelWithFont:[UIFont systemFontOfSize:11] color:timeColor];
	_remainingLabel.textAlignment = NSTextAlignmentRight;

	_titleLabel = [self labelWithFont:[UIFont boldSystemFontOfSize:18] color:dark];
	_titleLabel.textAlignment = NSTextAlignmentCenter;
	_artistLabel = [self labelWithFont:[UIFont systemFontOfSize:15] color:_accent];
	_artistLabel.textAlignment = NSTextAlignmentCenter;
	// Tap the artist line to open the artist, the title to open the album.
	_artistLabel.userInteractionEnabled = YES;
	[_artistLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openArtist)]];
	_titleLabel.userInteractionEnabled = YES;
	[_titleLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openAlbum)]];

	_previousButton = [self iconButton:[P7Theme previousIcon] action:@selector(previous)];
	_playButton = [self iconButton:[P7Theme playIcon] action:@selector(togglePlay)];
	_nextButton = [self iconButton:[P7Theme nextIcon] action:@selector(next)];
	for (UIButton *button in @[_previousButton, _playButton, _nextButton]) {
		button.tintColor = dark;
		[button addTarget:self action:@selector(pressDown:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
		[button addTarget:self action:@selector(pressUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchDragExit | UIControlEventTouchCancel];
	}

	_bufferingView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
	_bufferingView.hidesWhenStopped = YES;
	[self.view addSubview:_bufferingView];

	_volumeView = [MPVolumeView new];
	[self.view addSubview:_volumeView];

	_repeatButton = [self modeButton:@"Repeat" action:@selector(chooseRepeat)];
	_shuffleButton = [self modeButton:@"Shuffle" action:@selector(toggleShuffle)];
	_moreButton = [self iconButton:[P7Theme moreIcon] action:@selector(showMore)];
	_moreButton.tintColor = dark;
	_moreButton.accessibilityLabel = @"More";

	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc addObserver:self selector:@selector(update) name:P7PlayerDidChangeNotification object:nil];
	[nc addObserver:self selector:@selector(updateProgress) name:P7PlayerProgressNotification object:nil];
	[self applyAccent:_accent];
	_shownPlaying = YES;
	[self update];
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[_clock invalidate];
	_clock = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)viewDidDisappear:(BOOL)animated {
	[super viewDidDisappear:animated];
	[_clock invalidate];   // it keeps this controller alive otherwise
	_clock = nil;
}

- (void)tick {
	if ([P7Player shared].sleepDate) [self updatePositionLabel];
}

#pragma mark - Building

- (UIButton *)iconButton:(UIImage *)image action:(SEL)action {
	UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
	[button setImage:image forState:UIControlStateNormal];
	[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
	[self.view addSubview:button];
	return button;
}

- (UILabel *)labelWithFont:(UIFont *)font color:(UIColor *)color {
	UILabel *label = [UILabel new];
	label.font = font;
	label.textColor = color;
	[self.view addSubview:label];
	return label;
}

- (UIButton *)modeButton:(NSString *)title action:(SEL)action {
	UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
	button.titleLabel.font = [UIFont systemFontOfSize:15];
	button.layer.cornerRadius = 4;
	[button setTitle:title forState:UIControlStateNormal];
	[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
	[self.view addSubview:button];
	return button;
}

- (void)addParallaxTo:(UIView *)view amount:(CGFloat)amount {
	UIInterpolatingMotionEffect *x = [[UIInterpolatingMotionEffect alloc] initWithKeyPath:@"center.x" type:UIInterpolatingMotionEffectTypeTiltAlongHorizontalAxis];
	x.minimumRelativeValue = @(-amount);
	x.maximumRelativeValue = @(amount);
	UIInterpolatingMotionEffect *y = [[UIInterpolatingMotionEffect alloc] initWithKeyPath:@"center.y" type:UIInterpolatingMotionEffectTypeTiltAlongVerticalAxis];
	y.minimumRelativeValue = @(-amount);
	y.maximumRelativeValue = @(amount);
	UIMotionEffectGroup *group = [UIMotionEffectGroup new];
	group.motionEffects = @[x, y];
	[view addMotionEffect:group];
}

- (UIImage *)scrubberThumbWithColor:(UIColor *)color {
	UIGraphicsBeginImageContextWithOptions(CGSizeMake(9, 20), NO, 0);
	[color setFill];
	UIRectFill(CGRectMake(3, 2, 3, 16));
	UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return image;
}

- (void)viewDidLayoutSubviews {
	[super viewDidLayoutSubviews];
	CGFloat width = self.view.bounds.size.width;
	CGFloat height = self.view.bounds.size.height;

	_closeButton.frame = CGRectMake(4, 20, 50, 44);
	_queueButton.frame = CGRectMake(width - 54, 20, 50, 44);
	_positionLabel.frame = CGRectMake(60, 20, width - 120, 44);

	CGFloat bottomY = height - 42;
	_repeatButton.frame = CGRectMake(20, bottomY, 80, 30);
	_shuffleButton.frame = CGRectMake(width - 100, bottomY, 80, 30);
	_moreButton.frame = CGRectMake((width - 50) / 2, bottomY - 7, 50, 44);

	CGFloat volumeY = bottomY - 40;
	_volumeView.frame = CGRectMake(24, volumeY, width - 48, 34);

	CGFloat controlsY = volumeY - 58;
	_playButton.bounds = CGRectMake(0, 0, 64, 54);
	_playButton.center = CGPointMake(width / 2, controlsY + 27);
	_previousButton.bounds = _nextButton.bounds = CGRectMake(0, 0, 64, 54);
	_previousButton.center = CGPointMake(width / 2 - 90, controlsY + 27);
	_nextButton.center = CGPointMake(width / 2 + 90, controlsY + 27);
	_bufferingView.center = CGPointMake(width / 2, controlsY - 16);

	CGFloat artistY = controlsY - 24;
	_artistLabel.frame = CGRectMake(20, artistY, width - 40, 20);
	_titleLabel.frame = CGRectMake(20, artistY - 24, width - 40, 24);

	CGFloat scrubY = artistY - 24 - 42;
	_scrubber.frame = CGRectMake(14, scrubY, width - 28, 24);
	_elapsedLabel.frame = CGRectMake(16, scrubY + 22, 60, 14);
	_remainingLabel.frame = CGRectMake(width - 76, scrubY + 22, 60, 14);

	CGFloat artTop = 64;
	CGFloat artSize = MIN(width - 32, scrubY - 12 - artTop);
	CGAffineTransform transform = _artworkContainer.transform;
	_artworkContainer.transform = CGAffineTransformIdentity;
	_artworkContainer.frame = CGRectMake((width - artSize) / 2, artTop, artSize, artSize);
	_artworkContainer.layer.shadowPath = [UIBezierPath bezierPathWithRect:_artworkContainer.bounds].CGPath;
	_artworkView.frame = _artworkContainer.bounds;
	_artworkContainer.transform = transform;
}

#pragma mark - Updating

- (void)update {
	P7Player *player = [P7Player shared];
	P7Track *track = player.currentTrack;
	if (!track) {
		[self dismissViewControllerAnimated:YES completion:nil];
		return;
	}
	if (![_shownTrackID isEqualToString:track.trackID]) {
		BOOL first = _shownTrackID == nil;
		_shownTrackID = track.trackID;
		if (!first) {
			CATransition *fade = [CATransition animation];
			fade.type = kCATransitionFade;
			fade.duration = 0.3;
			[_titleLabel.layer addAnimation:fade forKey:@"fade"];
			[_artistLabel.layer addAnimation:fade forKey:@"fade"];
		}
		// The previous cover stays until the new one is loaded, so it doesn't flash.
		UIImage *placeholder = [P7Theme placeholderArtworkWithSize:280];
		[_artworkView p7_setCoverForTrackID:track.coverKey size:600 placeholder:placeholder whileLoading:_artworkView.image ?: placeholder];
	}
	_titleLabel.text = track.title;
	// Singles usually have the song's name as the album; don't repeat it.
	BOOL showAlbum = track.album.length && [track.album caseInsensitiveCompare:track.title] != NSOrderedSame;
	_artistLabel.text = showAlbum ? [NSString stringWithFormat:@"%@ — %@", track.artist, track.album] : track.artist;
	[self updatePositionLabel];

	[_playButton setImage:player.isPlaying ? [P7Theme pauseIcon] : [P7Theme playIcon] forState:UIControlStateNormal];
	[self setArtworkPlaying:player.isPlaying];

	[self styleModeButton:_shuffleButton title:@"Shuffle" active:player.shuffle];
	[self styleModeButton:_repeatButton title:@"Repeat" active:player.repeatMode != P7RepeatOff];
	[self updateProgress];
}

// The cover sits back a little while paused and springs forward when music plays.
- (void)setArtworkPlaying:(BOOL)playing {
	if (_shownPlaying == playing) return;
	_shownPlaying = playing;
	CGAffineTransform transform = playing ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.86, 0.86);
	[UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.62 initialSpringVelocity:0.4 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
		self->_artworkContainer.transform = transform;
		self->_artworkContainer.layer.shadowOpacity = playing ? 0.28 : 0.12;
	} completion:nil];
}

- (void)artworkChanged:(UIImage *)image {
	NSString *trackID = _shownTrackID;
	[P7ArtworkEffects effectsForImage:image completion:^(UIImage *blurred, UIColor *accent) {
		if (![trackID isEqualToString:self->_shownTrackID]) return;
		self->_backgroundView.image = blurred;
		[UIView animateWithDuration:0.4 animations:^{
			[self applyAccent:accent];
		}];
	}];
}

- (void)applyAccent:(UIColor *)accent {
	_accent = accent ?: [P7Theme tintColor];
	self.view.tintColor = _accent;
	_scrubber.minimumTrackTintColor = _accent;
	[_scrubber setThumbImage:[self scrubberThumbWithColor:_accent] forState:UIControlStateNormal];
	_artistLabel.textColor = _accent;
	// iOS 7 keeps drawing the "…" of a cut-off text in the old color until the text is set again.
	NSString *artist = _artistLabel.text;
	_artistLabel.text = nil;
	_artistLabel.text = artist;
	_volumeView.tintColor = _accent;
	P7Player *player = [P7Player shared];
	[self styleModeButton:_shuffleButton title:[_shuffleButton titleForState:UIControlStateNormal] active:player.shuffle];
	[self styleModeButton:_repeatButton title:[_repeatButton titleForState:UIControlStateNormal] active:player.repeatMode != P7RepeatOff];
}

- (void)styleModeButton:(UIButton *)button title:(NSString *)title active:(BOOL)active {
	[button setTitle:title forState:UIControlStateNormal];
	button.backgroundColor = active ? _accent : [UIColor clearColor];
	[button setTitleColor:active ? [UIColor whiteColor] : _accent forState:UIControlStateNormal];
}

- (void)updateProgress {
	if (_scrubbing) return;
	P7Player *player = [P7Player shared];
	NSTimeInterval duration = player.duration;
	NSTimeInterval time = MIN(player.currentTime, duration);
	_scrubber.maximumValue = MAX(duration, 1);
	_scrubber.value = time;
	_scrubber.enabled = duration > 0;
	[self setTimeLabels:time duration:duration];
	if (player.isBuffering) [_bufferingView startAnimating]; else [_bufferingView stopAnimating];
	if (player.sleepDate) [self updatePositionLabel];
}

// "3 of 20", plus the sleep timer when one is set.
- (void)updatePositionLabel {
	P7Player *player = [P7Player shared];
	NSString *text = [NSString stringWithFormat:@"%ld of %lu", (long)player.currentIndex + 1, (unsigned long)player.queue.count];
	if (player.sleepDate) {
		NSTimeInterval left = MAX(0, player.sleepDate.timeIntervalSinceNow);
		text = [text stringByAppendingFormat:@" · Sleep in %@", P7FormatDuration((NSInteger)ceil(left))];
	} else if (player.sleepAtEndOfTrack) {
		text = [text stringByAppendingString:@" · Sleep after this song"];
	}
	_positionLabel.text = text;
}

#pragma mark - More

- (void)showMore {
	P7Player *player = [P7Player shared];
	P7Track *track = player.currentTrack;
	if (!track) return;
	P7ActionSheet *sheet = [[P7ActionSheet alloc] initWithTitle:[NSString stringWithFormat:@"%@\n%@", track.title, track.artist]];
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
	P7Downloads *downloads = [P7Downloads shared];
	if (![downloads isDownloaded:track.trackID] && ![downloads isDownloading:track.trackID] && track.available) {
		[sheet addButton:@"Download" handler:^{ [downloads downloadTracks:@[track]]; }];
	}
	if ([P7Scrobbler shared].connected) {
		[sheet addButton:@"Love on Last.fm" handler:^{ [[P7Scrobbler shared] loveTrack:track]; }];
	}
	NSString *sleep = player.sleepDate || player.sleepAtEndOfTrack ? @"Sleep Timer (On)" : @"Sleep Timer";
	[sheet addButton:sleep handler:^{ [self showSleepTimer]; }];
	[sheet showFrom:self];
}

- (void)showSleepTimer {
	P7Player *player = [P7Player shared];
	P7ActionSheet *sheet = [[P7ActionSheet alloc] initWithTitle:@"Stop playing after"];
	for (NSNumber *minutes in @[@15, @30, @45, @60, @90]) {
		NSString *title = minutes.integerValue < 60 ? [NSString stringWithFormat:@"%@ minutes", minutes]
			: minutes.integerValue == 60 ? @"1 hour" : @"1 hour 30 minutes";
		[sheet addButton:title handler:^{ [player sleepAfter:minutes.integerValue * 60]; }];
	}
	[sheet addButton:@"End of This Song" handler:^{ [player sleepAtEndOfCurrentTrack]; }];
	if (player.sleepDate || player.sleepAtEndOfTrack) {
		[sheet addDestructiveButton:@"Turn Off Timer" handler:^{ [player sleepAfter:0]; }];
	}
	[sheet showFrom:self];
}

- (void)setTimeLabels:(NSTimeInterval)time duration:(NSTimeInterval)duration {
	_elapsedLabel.text = P7FormatDuration((NSInteger)time);
	_remainingLabel.text = [@"-" stringByAppendingString:P7FormatDuration((NSInteger)(duration - time))];
}

#pragma mark - Actions

- (void)pressDown:(UIButton *)button {
	[UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
		button.transform = CGAffineTransformMakeScale(0.82, 0.82);
	} completion:nil];
}

- (void)pressUp:(UIButton *)button {
	[UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.45 initialSpringVelocity:0.8 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
		button.transform = CGAffineTransformIdentity;
	} completion:nil];
}

- (void)close {
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (void)showQueue {
	UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[P7QueueViewController new]];
	[self presentViewController:nav animated:YES completion:nil];
}

- (void)togglePlay { [[P7Player shared] togglePlayPause]; }

- (void)openArtist {
	P7Track *track = [P7Player shared].currentTrack;
	if ([track.trackID hasPrefix:@"sp-"] || [track.trackID hasPrefix:@"yt-"] || [track.trackID hasPrefix:@"sc-"] || [track.trackID hasPrefix:@"ss-"]) [P7Navigator openArtistOfTrack:track from:self];
}

- (void)openAlbum {
	[P7Navigator openAlbumOfTrack:[P7Player shared].currentTrack from:self];
}
- (void)next { [[P7Player shared] next]; }
- (void)previous { [[P7Player shared] previous]; }

// Swiping the cover slides it out and changes the track, like flicking a record.
- (void)swipedArtworkLeft { [self slideArtwork:-1]; }
- (void)swipedArtworkRight { [self slideArtwork:1]; }

- (void)slideArtwork:(CGFloat)direction {
	CGFloat distance = _artworkContainer.bounds.size.width * 0.4;
	CGAffineTransform base = _artworkContainer.transform;
	[UIView animateWithDuration:0.18 animations:^{
		self->_artworkContainer.transform = CGAffineTransformTranslate(base, direction * distance, 0);
		self->_artworkContainer.alpha = 0;
	} completion:^(BOOL finished) {
		direction < 0 ? [[P7Player shared] next] : [[P7Player shared] previous];
		self->_artworkContainer.transform = CGAffineTransformTranslate(base, -direction * distance, 0);
		[UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.6 options:0 animations:^{
			self->_artworkContainer.transform = base;
			self->_artworkContainer.alpha = 1;
		} completion:nil];
	}];
}

- (void)toggleShuffle {
	P7Player *player = [P7Player shared];
	player.shuffle = !player.shuffle;
}

// Like the iOS 7 Music app: a sheet to pick the mode.
- (void)chooseRepeat {
	P7Player *player = [P7Player shared];
	P7ActionSheet *sheet = [[P7ActionSheet alloc] initWithTitle:nil];
	[sheet addButton:@"Repeat Song" handler:^{ player.repeatMode = P7RepeatOne; }];
	[sheet addButton:@"Repeat All" handler:^{ player.repeatMode = P7RepeatAll; }];
	if (player.repeatMode != P7RepeatOff) [sheet addButton:@"Repeat Off" handler:^{ player.repeatMode = P7RepeatOff; }];
	[sheet showFrom:self];
}

- (void)scrubStarted {
	_scrubbing = YES;
}

- (void)scrubMoved {
	[self setTimeLabels:_scrubber.value duration:_scrubber.maximumValue];
}

- (void)scrubEnded {
	[[P7Player shared] seekToTime:_scrubber.value];
	_scrubbing = NO;
}

@end

@implementation P7QueueViewController {
	BOOL _mutating;
}

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStylePlain])) {
		self.title = @"Up Next";
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.tableView.rowHeight = [P7TrackCell rowHeight];
	[self.tableView registerClass:[P7TrackCell class] forCellReuseIdentifier:@"Track"];
	self.navigationItem.leftBarButtonItem = self.editButtonItem;
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerChanged) name:P7PlayerDidChangeNotification object:nil];
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	NSInteger index = [P7Player shared].currentIndex;
	if (index != NSNotFound && index < [self.tableView numberOfRowsInSection:0]) {
		[self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:index inSection:0] atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
	}
}

- (void)playerChanged {
	if (!self.editing && !_mutating) [self.tableView reloadData];
}

- (void)done {
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return [P7Player shared].queue.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	P7TrackCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Track" forIndexPath:indexPath];
	cell.style = P7TrackCellStyleNumbered;
	[cell configureWithTrack:[P7Player shared].queue[indexPath.row] number:indexPath.row + 1];
	cell.showsReorderControl = YES;
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	[[P7Player shared] playQueueIndex:indexPath.row];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
	return indexPath.row != [P7Player shared].currentIndex;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
	return YES;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
	_mutating = YES;
	[[P7Player shared] moveQueueIndex:from.row toIndex:to.row];
	_mutating = NO;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
	if (editingStyle != UITableViewCellEditingStyleDelete) return;
	_mutating = YES;
	[[P7Player shared] removeQueueIndex:indexPath.row];
	[tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
	_mutating = NO;
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
	[super setEditing:editing animated:animated];
	if (!editing) [self.tableView reloadData];
}

@end
