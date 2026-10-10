#import "P7TrackCell.h"
#import "P7Theme.h"
#import "P7ImageCache.h"
#import "P7Downloads.h"
#import "P7Player.h"
#import "P7EqualizerView.h"
#import "P7FadeImageView.h"

@implementation P7TrackCell {
	P7Track *_track;
	P7FadeImageView *_artworkView;
	UILabel *_numberLabel;
	UILabel *_titleLabel;
	UILabel *_detailLabel;
	UIImageView *_stateView;
	UIProgressView *_progressView;
	UIButton *_moreButton;
	UIView *_playingOverlay;     // dark scrim over the artwork of the current track
	P7EqualizerView *_equalizer;
	UIActivityIndicatorView *_bufferingView;
}

+ (CGFloat)rowHeight {
	return 60;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
	if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier])) {
		_artworkView = [P7FadeImageView new];
		_artworkView.contentMode = UIViewContentModeScaleAspectFill;
		_artworkView.clipsToBounds = YES;
		[self.contentView addSubview:_artworkView];

		_numberLabel = [UILabel new];
		_numberLabel.font = [UIFont systemFontOfSize:15];
		_numberLabel.textColor = [P7Theme secondaryTextColor];
		_numberLabel.textAlignment = NSTextAlignmentCenter;
		[self.contentView addSubview:_numberLabel];

		_playingOverlay = [UIView new];
		_playingOverlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
		_playingOverlay.hidden = YES;
		[self.contentView addSubview:_playingOverlay];

		_equalizer = [[P7EqualizerView alloc] initWithFrame:CGRectMake(0, 0, 16, 14)];
		_equalizer.hidden = YES;
		[self.contentView addSubview:_equalizer];

		_bufferingView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
		_bufferingView.hidesWhenStopped = YES;
		[self.contentView addSubview:_bufferingView];

		_titleLabel = [UILabel new];
		_titleLabel.font = [UIFont systemFontOfSize:16];
		[self.contentView addSubview:_titleLabel];

		_detailLabel = [UILabel new];
		_detailLabel.font = [UIFont systemFontOfSize:12];
		_detailLabel.textColor = [P7Theme secondaryTextColor];
		[self.contentView addSubview:_detailLabel];

		_stateView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 14, 14)];
		_stateView.contentMode = UIViewContentModeScaleAspectFit;
		[self.contentView addSubview:_stateView];

		_progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
		_progressView.hidden = YES;
		[self.contentView addSubview:_progressView];

		_moreButton = [UIButton buttonWithType:UIButtonTypeSystem];
		[_moreButton setImage:[P7Theme moreIcon] forState:UIControlStateNormal];
		_moreButton.tintColor = [P7Theme secondaryTextColor];
		[_moreButton addTarget:self action:@selector(moreTapped) forControlEvents:UIControlEventTouchUpInside];
		[self.contentView addSubview:_moreButton];

		self.separatorInset = UIEdgeInsetsMake(0, 68, 0, 0);
		// Press and hold a song for the same menu as "…".
		[self addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressed:)]];
	}
	return self;
}

- (void)longPressed:(UILongPressGestureRecognizer *)gesture {
	if (gesture.state == UIGestureRecognizerStateBegan && self.moreHandler) self.moreHandler(self);
}

- (void)setStyle:(P7TrackCellStyle)style {
	_style = style;
	self.separatorInset = UIEdgeInsetsMake(0, style == P7TrackCellStyleArtwork ? 68 : 48, 0, 0);
	[self setNeedsLayout];
}

- (void)layoutSubviews {
	[super layoutSubviews];
	CGFloat width = self.contentView.bounds.size.width;
	CGFloat height = self.contentView.bounds.size.height;
	BOOL artwork = _style == P7TrackCellStyleArtwork;
	CGFloat textX = artwork ? 68 : 48;

	_artworkView.hidden = !artwork;
	_artworkView.frame = CGRectMake(15, (height - 44) / 2, 44, 44);
	_numberLabel.frame = CGRectMake(4, 0, 38, height);

	_moreButton.frame = CGRectMake(width - 44, 0, 44, height);
	CGFloat textWidth = width - textX - 44;
	_titleLabel.frame = CGRectMake(textX, 11, textWidth, 20);

	CGFloat detailX = textX;
	if (!_stateView.hidden) {
		_stateView.frame = CGRectMake(textX, 34, 12, 12);
		detailX += 16;
	}
	_detailLabel.frame = CGRectMake(detailX, 32, textWidth - (detailX - textX), 16);
	_progressView.frame = CGRectMake(textX, height - 6, textWidth, 2);
	_playingOverlay.frame = _artworkView.frame;
	CGPoint center = artwork ? _artworkView.center : _numberLabel.center;
	_equalizer.center = CGPointMake(roundf(center.x), roundf(center.y));
	_bufferingView.center = _equalizer.center;
}

- (void)configureWithTrack:(P7Track *)track number:(NSInteger)number {
	_track = track;
	_titleLabel.text = track.title;
	NSString *duration = track.duration > 0 ? P7FormatDuration(track.duration) : nil;
	_detailLabel.text = duration ? [NSString stringWithFormat:@"%@ · %@", track.artist, duration] : track.artist;
	_numberLabel.text = number > 0 ? [NSString stringWithFormat:@"%ld", (long)number] : nil;
	if (_style == P7TrackCellStyleArtwork) {
		[_artworkView p7_setCoverForTrackID:track.coverKey size:88 placeholder:[P7Theme placeholderArtworkWithSize:44]];
	}
	[self refreshState];
}

- (void)refreshState {
	P7Downloads *downloads = [P7Downloads shared];
	BOOL downloaded = [downloads isDownloaded:_track.trackID];
	BOOL downloading = [downloads isDownloading:_track.trackID];
	BOOL playable = _track.available || downloaded;

	_stateView.hidden = !downloaded;
	_stateView.image = [P7Theme downloadedIcon];
	_stateView.tintColor = [P7Theme secondaryTextColor];
	_progressView.hidden = !downloading;
	_progressView.progress = [downloads progressForTrackID:_track.trackID];

	P7Player *player = [P7Player shared];
	BOOL current = [player.currentTrack.trackID isEqualToString:_track.trackID];
	BOOL artwork = _style == P7TrackCellStyleArtwork;
	_titleLabel.textColor = current ? [P7Theme tintColor] : (playable ? [UIColor blackColor] : [P7Theme secondaryTextColor]);
	_playingOverlay.hidden = !(current && artwork);
	// While the server fetches a song the first time, show a spinner instead of the bars.
	BOOL buffering = current && player.isBuffering;
	_equalizer.hidden = !current || buffering;
	_equalizer.barColor = artwork ? [UIColor whiteColor] : [P7Theme tintColor];
	_equalizer.animating = current && player.isPlaying && !buffering;
	_bufferingView.color = artwork ? [UIColor whiteColor] : [P7Theme secondaryTextColor];
	buffering ? [_bufferingView startAnimating] : [_bufferingView stopAnimating];
	_numberLabel.hidden = artwork || current;
	self.contentView.alpha = playable ? 1 : 0.5;
	[self setNeedsLayout];
}

- (void)moreTapped {
	if (self.moreHandler) self.moreHandler(self);
}

@end
