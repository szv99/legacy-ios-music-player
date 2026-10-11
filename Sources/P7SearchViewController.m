#import "P7SearchViewController.h"
#import "P7API.h"
#import "P7Settings.h"
#import "P7Theme.h"
#import "P7EntityCell.h"
#import "P7Navigator.h"

typedef NS_ENUM(NSInteger, P7SearchSource) {
	P7SearchSourceSpotify,
	P7SearchSourceYouTube,
	P7SearchSourceSoundCloud,
	P7SearchSourceLibrary,
	P7SearchSourceSubsonic,
	P7SearchSourceYouTubeVideos,   // plain YouTube; P7SearchSourceYouTube is YouTube Music
	P7SearchSourceCount,
};

static NSString *P7SearchSourceTitle(P7SearchSource source) {
	return @[@"Spotify", @"YT Music", @"SoundCloud", @"Library", @"Server", @"YouTube"][source];
}

// The scope bar of a search bar (no public accessor).
static UISegmentedControl *P7SegmentedControlIn(UIView *view) {
	if ([view isKindOfClass:[UISegmentedControl class]]) return (UISegmentedControl *)view;
	for (UIView *subview in view.subviews) {
		UISegmentedControl *found = P7SegmentedControlIn(subview);
		if (found) return found;
	}
	return nil;
}

static NSString *const kRecentSearchesKey = @"P7RecentSearches";
static NSString *const kSelectedSourceKey = @"P7SearchSourceIndex";
static NSString *const kEntityCell = @"P7EntityCell";

// Results for one source; each source keeps its own so switching is instant.
@interface P7SearchResults : NSObject
@property (nonatomic, copy) NSString *query;
@property (nonatomic, copy) NSArray *tracks;       // nil until the first answer
@property (nonatomic, copy) NSArray *artists;
@property (nonatomic, copy) NSArray *albums;
@property (nonatomic, copy) NSArray *playlists;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic) BOOL loading;
- (BOOL)isEmpty;
@end

@implementation P7SearchResults

- (BOOL)isEmpty {
	return !self.tracks.count && !self.artists.count && !self.albums.count && !self.playlists.count;
}

@end

@interface P7SearchViewController () <UISearchBarDelegate>
@end

@implementation P7SearchViewController {
	UISearchBar *_searchBar;     // its scope bar picks the source
	NSArray *_scopes;           // P7SearchSource numbers the selected backend can search
	NSArray *_results;          // P7SearchResults per source
	NSTimer *_debounce;
	UIView *_loadingFooter;
}

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStylePlain])) {
		self.title = @"Search";
		self.tabBarItem = [[UITabBarItem alloc] initWithTabBarSystemItem:UITabBarSystemItemSearch tag:0];
		NSMutableArray *results = [NSMutableArray new];
		for (NSInteger i = 0; i < P7SearchSourceCount; i++) [results addObject:[P7SearchResults new]];
		_results = results;
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	[self.tableView registerClass:[P7EntityCell class] forCellReuseIdentifier:kEntityCell];
	_searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
	_searchBar.delegate = self;
	[self updateScopes];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged) name:P7SettingsDidChangeNotification object:nil];
	_searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
	_searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
	self.tableView.tableHeaderView = _searchBar;
	self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;

	_loadingFooter = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 50)];
	UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
	spinner.center = CGPointMake(_loadingFooter.bounds.size.width / 2, 25);
	spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
	[spinner startAnimating];
	[_loadingFooter addSubview:spinner];

	[self updatePlaceholder];
	[self render];
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	if (!_searchBar.text.length) [_searchBar becomeFirstResponder];
}

#pragma mark - State

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

// The scope bar lists what the selected backend can search; a single source hides it.
- (void)updateScopes {
	switch ([P7Settings shared].backend) {
		case P7BackendDevice: _scopes = @[@(P7SearchSourceYouTube), @(P7SearchSourceYouTubeVideos), @(P7SearchSourceLibrary)]; break;
		case P7BackendSubsonic: _scopes = @[@(P7SearchSourceSubsonic)]; break;
		default: _scopes = @[@(P7SearchSourceSpotify), @(P7SearchSourceYouTube), @(P7SearchSourceYouTubeVideos), @(P7SearchSourceSoundCloud), @(P7SearchSourceLibrary)]; break;
	}
	NSMutableArray *titles = [NSMutableArray new];
	for (NSNumber *source in _scopes) [titles addObject:P7SearchSourceTitle(source.integerValue)];
	_searchBar.scopeButtonTitles = titles;
	_searchBar.showsScopeBar = _scopes.count > 1;
	NSUInteger saved = [_scopes indexOfObject:@([[NSUserDefaults standardUserDefaults] integerForKey:kSelectedSourceKey])];
	_searchBar.selectedScopeButtonIndex = saved == NSNotFound ? 0 : saved;
	[_searchBar sizeToFit];
	// Five equal segments cut "SoundCloud" off; sized to their titles they all fit.
	P7SegmentedControlIn(_searchBar).apportionsSegmentWidthsByContent = _scopes.count > 4;
	self.tableView.tableHeaderView = _searchBar;
	[self updatePlaceholder];
}

- (void)settingsChanged {
	for (P7SearchResults *results in _results) {
		[results.task cancel];
		results.tracks = nil;
		results.query = nil;
		results.loading = NO;
		results.error = nil;
	}
	if (!self.isViewLoaded) return;
	[self updateScopes];
	[self searchIfNeeded];
	[self render];
}

- (P7SearchSource)source {
	NSInteger index = _searchBar.selectedScopeButtonIndex;
	return index >= 0 && index < (NSInteger)_scopes.count ? (P7SearchSource)[_scopes[index] integerValue] : (P7SearchSource)[_scopes.firstObject integerValue];
}

- (P7SearchResults *)current {
	return _results[[self source]];
}

- (NSString *)query {
	return [_searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

- (BOOL)showingRecents {
	return [self query].length == 0;
}

- (void)updatePlaceholder {
	switch ([self source]) {
		case P7SearchSourceSpotify: _searchBar.placeholder = @"Search Spotify"; break;
		case P7SearchSourceYouTube: _searchBar.placeholder = @"Search YouTube Music"; break;
		case P7SearchSourceYouTubeVideos: _searchBar.placeholder = @"Search YouTube Videos"; break;
		case P7SearchSourceSoundCloud: _searchBar.placeholder = @"Search SoundCloud"; break;
		case P7SearchSourceSubsonic: _searchBar.placeholder = @"Search Your Server"; break;
		default: _searchBar.placeholder = @"Search Your Songs"; break;
	}
}

- (NSArray *)recentSearches {
	return [[NSUserDefaults standardUserDefaults] arrayForKey:kRecentSearchesKey] ?: @[];
}

- (void)rememberSearch:(NSString *)query {
	if (!query.length) return;
	NSMutableArray *recents = [[self recentSearches] mutableCopy];
	[recents removeObject:query];
	[recents insertObject:query atIndex:0];
	if (recents.count > 12) [recents removeObjectsInRange:NSMakeRange(12, recents.count - 12)];
	[[NSUserDefaults standardUserDefaults] setObject:recents forKey:kRecentSearchesKey];
}

#pragma mark - Searching

- (void)sourceChanged {
	[[NSUserDefaults standardUserDefaults] setInteger:[self source] forKey:kSelectedSourceKey];
	[self updatePlaceholder];
	[_debounce invalidate];
	[self searchIfNeeded];
	[self render];
}

- (void)scheduleSearch {
	[_debounce invalidate];
	NSTimeInterval delay = [self source] == P7SearchSourceLibrary ? 0.1 : 0.35;
	_debounce = [NSTimer scheduledTimerWithTimeInterval:delay target:self selector:@selector(searchIfNeeded) userInfo:nil repeats:NO];
}

- (void)searchIfNeeded {
	NSString *query = [self query];
	P7SearchResults *results = [self current];
	if (!query.length || ([results.query isEqualToString:query] && (results.tracks || results.loading))) {
		[self render];
		return;
	}
	if (![P7Settings shared].isConfigured) {
		results.error = [NSError errorWithDomain:P7APIErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Add your server address in Settings."}];
		[self render];
		return;
	}
	[results.task cancel];
	results.query = query;
	results.loading = YES;
	results.error = nil;
	P7SearchSource source = [self source];

	void (^completion)(NSDictionary *, NSError *) = ^(NSDictionary *found, NSError *error) {
		if (![results.query isEqualToString:query]) return; // a newer search replaced this one
		results.loading = NO;
		results.task = nil;
		if (error) {
			results.error = error;
		} else {
			results.tracks = found[@"tracks"] ?: @[];
			results.artists = found[@"artists"];
			results.albums = found[@"albums"];
			results.playlists = found[@"playlists"];
		}
		if ([self source] == source) [self render];
	};
	if (source == P7SearchSourceLibrary) {
		results.task = [[P7API shared] searchTracks:query completion:^(NSArray *tracks, NSError *error) {
			completion(tracks ? @{@"tracks": tracks} : nil, error);
		}];
	} else {
		NSString *name = @{@(P7SearchSourceSpotify): @"spotify", @(P7SearchSourceSoundCloud): @"soundcloud", @(P7SearchSourceSubsonic): @"subsonic",
			@(P7SearchSourceYouTubeVideos): @"youtube-videos"}[@(source)] ?: @"youtube";
		results.task = [[P7API shared] search:query source:name completion:completion];
	}
	[self render];
}

- (void)reload {
	[self current].tracks = nil;
	[self current].query = nil;
	[self searchIfNeeded];
}

// Old results stay visible while a new search runs, with a spinner underneath.
- (void)render {
	P7SearchResults *results = [self current];
	BOOL recents = [self showingRecents];
	BOOL stale = results.tracks && ![results.query isEqualToString:[self query]];
	[self.tableView reloadData];
	self.tableView.tableFooterView = (!recents && results.loading && ![results isEmpty]) ? _loadingFooter : [UIView new];

	if (recents) {
		NSString *hint = @[@"Search YouTube Music, YouTube videos or your own songs.", @"Search Spotify, YouTube Music, YouTube videos, SoundCloud or your own songs.", @"Search the music on your server."][[P7Settings shared].backend];
		[self recentSearches].count ? [self hideMessage] : [self showMessage:[hint stringByAppendingString:@"\nTap a result to play it."] retry:NO];
	} else if (results.loading && [results isEmpty]) {
		[self showLoading];
	} else if (results.error && !results.loading) {
		[self showMessage:results.error.localizedDescription retry:YES];
	} else if (!results.loading && !stale && results.tracks && [results isEmpty]) {
		[self showMessage:[NSString stringWithFormat:@"No results for “%@”", [self query]] retry:NO];
	} else {
		[self hideMessage];
	}
}

- (void)searchFor:(NSString *)query source:(NSInteger)source {
	(void)self.view;
	NSUInteger index = [_scopes indexOfObject:@(source)];
	_searchBar.selectedScopeButtonIndex = index == NSNotFound ? 0 : index;
	[self updatePlaceholder];
	_searchBar.text = query;
	[_searchBar resignFirstResponder];
	[self searchIfNeeded];
}

#pragma mark - Search bar

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
	if (![self query].length) {
		[_debounce invalidate];
		[self render];
		return;
	}
	[self scheduleSearch];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
	[searchBar resignFirstResponder];
	[_debounce invalidate];
	[self rememberSearch:[self query]];
	[self searchIfNeeded];
}

- (void)searchBar:(UISearchBar *)searchBar selectedScopeButtonIndexDidChange:(NSInteger)selectedScope {
	[self sourceChanged];
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
	[searchBar setShowsCancelButton:YES animated:YES];
}

- (void)searchBarTextDidEndEditing:(UISearchBar *)searchBar {
	[searchBar setShowsCancelButton:[self query].length > 0 animated:YES];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
	searchBar.text = nil;
	[searchBar resignFirstResponder];
	[searchBar setShowsCancelButton:NO animated:YES];
	[self render];
}

#pragma mark - Table

- (NSArray *)visibleTracks {
	return [self showingRecents] ? nil : [self current].tracks;
}

// Artists first (that's usually who you typed), then songs, then albums and playlists.
- (NSArray *)sectionKeys {
	if ([self showingRecents]) return @[@"recents"];
	P7SearchResults *results = [self current];
	NSMutableArray *keys = [NSMutableArray new];
	for (NSString *key in @[@"artists", @"tracks", @"albums", @"playlists"]) {
		if ([[results valueForKey:key] count]) [keys addObject:key];
	}
	return keys;
}

- (NSArray *)rowsInSection:(NSInteger)section {
	NSArray *keys = [self sectionKeys];
	if (section >= (NSInteger)keys.count) return @[];   // the table can ask before reloadData catches up
	NSString *key = keys[section];
	if ([key isEqualToString:@"recents"]) return [self recentSearches];
	return [[self current] valueForKey:key];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return [self sectionKeys].count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return [self rowsInSection:section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	NSArray *keys = [self sectionKeys];
	if (section >= (NSInteger)keys.count) return nil;
	NSString *key = keys[section];
	if ([key isEqualToString:@"recents"]) return [self recentSearches].count ? @"Recent Searches" : nil;
	if ([key isEqualToString:@"artists"]) return @"Artists";
	if ([key isEqualToString:@"albums"]) return @"Albums";
	if ([key isEqualToString:@"playlists"]) return @"Playlists";
	NSString *source = @[@"Spotify", @"YouTube Music", @"SoundCloud", @"Your Songs", @"Your Server", @"YouTube"][[self source]];
	NSInteger count = [self visibleTracks].count;
	NSString *counted = [self source] == P7SearchSourceYouTubeVideos ? [NSString stringWithFormat:count == 1 ? @"%ld video" : @"%ld videos", (long)count] : P7TrackCountString(count);
	return [NSString stringWithFormat:@"%@ · %@", source, counted];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
	return [self showingRecents] ? 44 : [P7TrackCell rowHeight];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	NSArray *rows = [self rowsInSection:indexPath.section];
	id item = indexPath.row < (NSInteger)rows.count ? rows[indexPath.row] : nil;
	if ([self showingRecents] || [item isKindOfClass:[NSString class]]) {
		UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Recent"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Recent"];
		cell.textLabel.text = [item isKindOfClass:[NSString class]] ? item : nil;
		cell.textLabel.textColor = [P7Theme tintColor];
		return cell;
	}
	if ([item isKindOfClass:[P7Track class]]) return [self trackCellForTrack:item number:0];
	P7EntityCell *cell = [tableView dequeueReusableCellWithIdentifier:kEntityCell forIndexPath:indexPath];
	[cell configureWithEntity:item];
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if ([self showingRecents]) {
		if (indexPath.row >= (NSInteger)[self recentSearches].count) return;
		_searchBar.text = [self recentSearches][indexPath.row];
		[_searchBar resignFirstResponder];
		[self searchIfNeeded];
		return;
	}
	[self rememberSearch:[self query]];
	NSArray *rows = [self rowsInSection:indexPath.section];
	if (indexPath.row >= (NSInteger)rows.count) return;
	id item = rows[indexPath.row];
	if ([item isKindOfClass:[P7Track class]]) {
		[self playTracks:[self visibleTracks] startIndex:indexPath.row];
	} else {
		[_searchBar resignFirstResponder];
		[P7Navigator openEntity:item from:self];
	}
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
	return [self showingRecents];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
	NSMutableArray *recents = [[self recentSearches] mutableCopy];
	[recents removeObjectAtIndex:indexPath.row];
	[[NSUserDefaults standardUserDefaults] setObject:recents forKey:kRecentSearchesKey];
	[self render];
}

@end
