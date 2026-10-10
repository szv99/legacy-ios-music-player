#import "P7ArtistViewController.h"
#import "P7API.h"
#import "P7Player.h"
#import "P7Blocks.h"
#import "P7Theme.h"
#import "P7ImageCache.h"
#import "P7FadeImageView.h"
#import "P7EntityCell.h"
#import "P7Navigator.h"

static NSString *const kEntityCell = @"P7EntityCell";
static const NSInteger kCollapsedTracks = 5;
static const NSInteger kCollapsedItems = 6;

@implementation P7ArtistViewController {
	P7Entity *_entity;
	P7Artist *_artist;
	NSMutableSet *_expanded;        // section indexes showing every row
	UIView *_header;
	UIView *_bannerClip;
	P7FadeImageView *_banner;
	CAGradientLayer *_shade;
	UILabel *_nameLabel;
	UILabel *_subtitleLabel;
	UIButton *_playButton;
	UIButton *_shuffleButton;
	UIButton *_addButton;
	CGFloat _bannerHeight;
	BOOL _loadingSongs;
	BOOL _importing;
}

- (instancetype)initWithEntity:(P7Entity *)entity {
	if ((self = [super initWithStyle:UITableViewStylePlain])) {
		_entity = entity;
		_expanded = [NSMutableSet new];
		self.title = entity.name;
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	[self.tableView registerClass:[P7EntityCell class] forCellReuseIdentifier:kEntityCell];
	self.tableView.tableHeaderView = [self buildHeader];
	[self updateHeader];
	[self reload];
}

#pragma mark - Header

- (UIButton *)borderedButton:(NSString *)title action:(SEL)action {
	UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
	[button setTitle:title forState:UIControlStateNormal];
	button.titleLabel.font = [UIFont systemFontOfSize:15];
	button.layer.borderWidth = 1;
	button.layer.cornerRadius = 4;
	button.layer.borderColor = [P7Theme tintColor].CGColor;
	[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
	return button;
}

- (UIView *)buildHeader {
	CGFloat width = self.view.bounds.size.width;
	_bannerHeight = roundf(width * 0.5);
	_header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, _bannerHeight + 54)];

	// The banner stretches when pulled down; the clip view keeps it from covering the rows.
	_bannerClip = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, _bannerHeight)];
	_bannerClip.clipsToBounds = YES;
	_bannerClip.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1];
	[_header addSubview:_bannerClip];
	_banner = [[P7FadeImageView alloc] initWithFrame:_bannerClip.bounds];
	_banner.fadeDuration = 0.4;
	_banner.contentMode = UIViewContentModeScaleAspectFill;
	[_bannerClip addSubview:_banner];

	_shade = [CAGradientLayer layer];
	_shade.colors = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor, (id)[UIColor colorWithWhite:0 alpha:0.6].CGColor];
	_shade.locations = @[@0.35, @1];
	_shade.frame = _bannerClip.bounds;
	[_bannerClip.layer addSublayer:_shade];

	_nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, _bannerHeight - 58, width - 30, 32)];
	_nameLabel.font = [UIFont boldSystemFontOfSize:26];
	_nameLabel.textColor = [UIColor whiteColor];
	_nameLabel.adjustsFontSizeToFitWidth = YES;
	_nameLabel.minimumScaleFactor = 0.6;
	[_header addSubview:_nameLabel];
	_subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, _bannerHeight - 26, width - 30, 16)];
	_subtitleLabel.font = [UIFont systemFontOfSize:13];
	_subtitleLabel.textColor = [UIColor colorWithWhite:1 alpha:0.85];
	[_header addSubview:_subtitleLabel];

	_playButton = [self borderedButton:@"Play" action:@selector(playTapped)];
	_playButton.frame = CGRectMake(15, _bannerHeight + 12, 64, 30);
	[_header addSubview:_playButton];
	_shuffleButton = [self borderedButton:@"Shuffle" action:@selector(shuffleTapped)];
	_shuffleButton.frame = CGRectMake(87, _bannerHeight + 12, 72, 30);
	[_header addSubview:_shuffleButton];
	_addButton = [self borderedButton:@"Add to Library" action:@selector(addTapped)];
	_addButton.frame = CGRectMake(width - 15 - 118, _bannerHeight + 12, 118, 30);
	[_header addSubview:_addButton];

	UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, _header.bounds.size.height - 0.5, width, 0.5)];
	line.backgroundColor = [P7Theme separatorColor];
	[_header addSubview:line];
	return _header;
}

- (void)updateHeader {
	P7Entity *entity = _artist ?: _entity;
	_nameLabel.text = entity.name;
	NSString *source = @{@"spotify": @"Spotify", @"youtube": @"YouTube", @"soundcloud": @"SoundCloud"}[entity.source ?: @""];
	NSMutableArray *parts = [NSMutableArray new];
	if (source) [parts addObject:source];
	if (entity.subtitle.length && ![entity.subtitle isEqualToString:@"Artist"]) [parts addObject:entity.subtitle];
	_subtitleLabel.text = [parts componentsJoinedByString:@" · "];

	NSString *bannerKey = _artist.bannerKey;
	if (bannerKey.length) {
		NSString *version = [_artist.bannerKey isEqualToString:_artist.entityID] ? [_artist stringForKey:@"coverVersion"] : @"";
		NSString *key = [NSString stringWithFormat:@"%@|%@|wide", bannerKey, version ?: @""];
		[_banner p7_setCoverForTrackID:key size:640 placeholder:nil];
	}

	BOOL imported = _artist.imported;
	[_addButton setTitle:_importing ? @"Adding…" : imported ? @"In Library" : @"Add to Library" forState:UIControlStateNormal];
	_addButton.enabled = !imported && !_importing && _artist != nil;
	_addButton.layer.borderColor = (_addButton.enabled ? [P7Theme tintColor] : [P7Theme separatorColor]).CGColor;
	_playButton.enabled = _shuffleButton.enabled = !_loadingSongs;
}

// Pulling down stretches the banner instead of showing a gap above it.
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
	CGFloat pull = -(scrollView.contentOffset.y + scrollView.contentInset.top);
	CGRect frame = CGRectMake(0, 0, _header.bounds.size.width, _bannerHeight);
	if (pull > 0) frame = CGRectMake(0, -pull, frame.size.width, _bannerHeight + pull);
	_bannerClip.frame = frame;
	_banner.frame = _bannerClip.bounds;
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	_shade.frame = _bannerClip.bounds;
	[CATransaction commit];
}

#pragma mark - Data

- (void)reload {
	if (!_artist) [self showLoading];
	[[P7API shared] fetchArtist:_entity.entityID completion:^(P7Artist *artist, NSError *error) {
		[self endRefreshing];
		if (error || !artist) {
			if (!self->_artist) [self showMessage:error.localizedDescription ?: @"Couldn't load the artist." retry:YES];
			return;
		}
		self->_artist = artist;
		self.title = artist.name;
		artist.sections.count ? [self hideMessage] : [self showMessage:@"Nothing here yet." retry:NO];
		[self updateHeader];
		[self.tableView reloadData];
	}];
}

// Every song of the artist (discography / channel songs) is a server collection with the same id.
- (void)loadAllSongs:(void (^)(NSArray *tracks))completion {
	_loadingSongs = YES;
	[self updateHeader];
	[[P7API shared] fetchCollection:_entity.entityID completion:^(P7Playlist *playlist, NSError *error) {
		self->_loadingSongs = NO;
		[self updateHeader];
		NSArray *tracks = playlist.tracks;
		if (!tracks.count) {
			NSMutableOrderedSet *visible = [NSMutableOrderedSet new];
			for (P7Section *section in self->_artist.sections) [visible addObjectsFromArray:section.tracks];
			tracks = visible.array;
		}
		if (tracks.count) completion(tracks);
		else if (error) [P7Alert showError:error title:@"Couldn't Load Songs"];
	}];
}

#pragma mark - Actions

- (void)playTapped {
	[self loadAllSongs:^(NSArray *tracks) {
		[P7Player shared].shuffle = NO;
		[self playTracks:tracks startIndex:0];
	}];
}

- (void)shuffleTapped {
	[self loadAllSongs:^(NSArray *tracks) {
		[[P7Player shared] shuffleTracks:tracks];
	}];
}

- (void)addTapped {
	if (!_artist.url.length || _importing) return;
	_importing = YES;
	[self updateHeader];
	[[P7API shared] importURL:_artist.url completion:^(P7Playlist *playlist, BOOL background, NSError *error) {
		self->_importing = NO;
		if (error) {
			[self updateHeader];
			[P7Alert showError:error title:@"Couldn't Add"];
			return;
		}
		NSMutableDictionary *raw = [self->_artist.raw mutableCopy];
		raw[@"imported"] = @YES;
		self->_artist = [P7Artist itemWithDictionary:raw];
		[self updateHeader];
		NSString *message = [NSString stringWithFormat:@"“%@” is in Playlists with %@.", playlist.name ?: self->_artist.name, P7TrackCountString(playlist.trackCount)];
		[P7Alert showMessage:message title:@"Added to Library"];
	}];
}

#pragma mark - Table

- (P7Section *)sectionAt:(NSInteger)index {
	return _artist.sections[index];
}

- (BOOL)isTrackSection:(P7Section *)section {
	return section.tracks.count > 0;
}

- (NSInteger)visibleCountIn:(NSInteger)index {
	P7Section *section = [self sectionAt:index];
	NSInteger count = [self isTrackSection:section] ? section.tracks.count : section.items.count;
	NSInteger limit = [self isTrackSection:section] ? kCollapsedTracks : kCollapsedItems;
	return [_expanded containsObject:@(index)] ? count : MIN(count, limit);
}

- (BOOL)hasShowAllRow:(NSInteger)index {
	P7Section *section = [self sectionAt:index];
	NSInteger count = [self isTrackSection:section] ? section.tracks.count : section.items.count;
	return ![_expanded containsObject:@(index)] && count > [self visibleCountIn:index];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return _artist.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)index {
	return [self visibleCountIn:index] + ([self hasShowAllRow:index] ? 1 : 0) + ([self sectionAt:index].more ? 1 : 0);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)index {
	return [self sectionAt:index].title;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
	return indexPath.row < [self visibleCountIn:indexPath.section] ? [P7TrackCell rowHeight] : 44;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	P7Section *section = [self sectionAt:indexPath.section];
	NSInteger visible = [self visibleCountIn:indexPath.section];
	if (indexPath.row < visible) {
		if ([self isTrackSection:section]) return [self trackCellForTrack:section.tracks[indexPath.row] number:0];
		P7EntityCell *cell = [tableView dequeueReusableCellWithIdentifier:kEntityCell forIndexPath:indexPath];
		[cell configureWithEntity:section.items[indexPath.row]];
		return cell;
	}
	P7EntityCell *cell = [tableView dequeueReusableCellWithIdentifier:kEntityCell forIndexPath:indexPath];
	if (indexPath.row == visible && [self hasShowAllRow:indexPath.section]) {
		NSInteger total = [self isTrackSection:section] ? section.tracks.count : section.items.count;
		[cell configureWithTitle:[NSString stringWithFormat:@"Show All %ld", (long)total]];
		cell.accessoryType = UITableViewCellAccessoryNone;
	} else {
		[cell configureWithTitle:@"All Songs"];
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
	}
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	P7Section *section = [self sectionAt:indexPath.section];
	NSInteger visible = [self visibleCountIn:indexPath.section];
	if (indexPath.row < visible) {
		if ([self isTrackSection:section]) {
			[self playTracks:section.tracks startIndex:indexPath.row];
		} else {
			[P7Navigator openEntity:section.items[indexPath.row] from:self];
		}
	} else if (indexPath.row == visible && [self hasShowAllRow:indexPath.section]) {
		[_expanded addObject:@(indexPath.section)];
		[tableView reloadSections:[NSIndexSet indexSetWithIndex:indexPath.section] withRowAnimation:UITableViewRowAnimationFade];
	} else if (section.more) {
		[P7Navigator openEntity:section.more from:self];
	}
}

@end
