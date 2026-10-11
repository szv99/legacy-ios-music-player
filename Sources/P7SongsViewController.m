#import "P7SongsViewController.h"
#import "P7API.h"
#import "P7Player.h"
#import "P7Settings.h"
#import "P7Theme.h"

@interface P7SongsViewController () <UISearchBarDelegate>
@end

@implementation P7SongsViewController {
	NSArray *_allTracks;      // sorted by title
	NSArray *_sections;       // array of arrays of P7Track (indexed mode)
	NSArray *_sectionTitles;
	NSArray *_results;        // search mode
	UISearchBar *_searchBar;
	UILocalizedIndexedCollation *_collation;
}

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStylePlain])) {
		self.title = @"Songs";
		self.tabBarItem.image = [P7Theme tabSongsIcon];
		_collation = [UILocalizedIndexedCollation currentCollation];
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	_searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
	_searchBar.placeholder = @"Search";
	_searchBar.delegate = self;
	_searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
	self.tableView.tableHeaderView = _searchBar;
	self.tableView.sectionIndexColor = [P7Theme tintColor];
	self.tableView.sectionIndexBackgroundColor = [UIColor clearColor];
	self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
	[self enablePullToRefresh];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged) name:P7SettingsDidChangeNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload) name:P7LibraryDidChangeNotification object:nil];
	[self reload];
}

// Another source has other songs; don't show the old ones while loading.
- (void)settingsChanged {
	_allTracks = nil;
	_sections = nil;
	_sectionTitles = nil;
	_results = nil;
	[self.tableView reloadData];
	[self reload];
}

- (BOOL)isSearching {
	return _searchBar.text.length > 0;
}

- (void)reload {
	if (![P7Settings shared].isConfigured) {
		[self endRefreshing];
		[self showMessage:@"Add your server address in Settings." retry:NO];
		return;
	}
	if (!_allTracks.count) [self showLoading];
	[[P7API shared] searchTracks:nil completion:^(NSArray *tracks, NSError *error) {
		[self endRefreshing];
		if (error) {
			if (!self->_allTracks.count) [self showMessage:P7ErrorMessage(error) retry:YES];
			return;
		}
		self->_allTracks = [tracks sortedArrayUsingComparator:^NSComparisonResult(P7Track *a, P7Track *b) {
			return [a.title localizedCaseInsensitiveCompare:b.title];
		}];
		[self buildSections];
		[self applySearch];
	}];
}

- (void)buildSections {
	NSInteger count = _collation.sectionTitles.count;
	NSMutableArray *buckets = [NSMutableArray arrayWithCapacity:count];
	for (NSInteger i = 0; i < count; i++) [buckets addObject:[NSMutableArray new]];
	for (P7Track *track in _allTracks) {
		NSInteger section = [_collation sectionForObject:track collationStringSelector:@selector(title)];
		[buckets[section] addObject:track];
	}
	NSMutableArray *sections = [NSMutableArray new];
	NSMutableArray *titles = [NSMutableArray new];
	for (NSInteger i = 0; i < count; i++) {
		if (![buckets[i] count]) continue;
		[sections addObject:buckets[i]];
		[titles addObject:_collation.sectionTitles[i]];
	}
	_sections = sections;
	_sectionTitles = titles;
}

- (void)applySearch {
	if ([self isSearching]) {
		NSString *query = _searchBar.text;
		NSMutableArray *results = [NSMutableArray new];
		for (P7Track *track in _allTracks) {
			NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@", track.title, track.artist, track.album ?: @""];
			if ([haystack rangeOfString:query options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) {
				[results addObject:track];
			}
		}
		_results = results;
		results.count ? [self hideMessage] : [self showMessage:@"No Results" retry:NO];
	} else {
		_results = nil;
		_allTracks.count ? [self hideMessage] : [self showMessage:@"Your library is empty." retry:NO];
	}
	[self.tableView reloadData];
}

- (NSArray *)tracksInSection:(NSInteger)section {
	if ([self isSearching]) return _results;
	if (section == 0) return @[];
	return _sections[section - 1];
}

#pragma mark - Search bar

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
	[self applySearch];
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
	[searchBar setShowsCancelButton:YES animated:YES];
}

- (void)searchBarTextDidEndEditing:(UISearchBar *)searchBar {
	[searchBar setShowsCancelButton:searchBar.text.length > 0 animated:YES];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
	searchBar.text = nil;
	[searchBar resignFirstResponder];
	[searchBar setShowsCancelButton:NO animated:YES];
	[self applySearch];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
	[searchBar resignFirstResponder];
}

#pragma mark - Table

// Section 0 holds the "Shuffle" row when not searching.
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return [self isSearching] ? 1 : _sections.count + (_allTracks.count ? 1 : 0);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	if (![self isSearching] && section == 0) return 1;
	return [self tracksInSection:section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	if ([self isSearching] || section == 0) return nil;
	return _sectionTitles[section - 1];
}

- (NSArray *)sectionIndexTitlesForTableView:(UITableView *)tableView {
	return [self isSearching] || _allTracks.count < 30 ? nil : [@[UITableViewIndexSearch] arrayByAddingObjectsFromArray:_sectionTitles];
}

- (NSInteger)tableView:(UITableView *)tableView sectionForSectionIndexTitle:(NSString *)title atIndex:(NSInteger)index {
	if (index == 0) {
		[tableView scrollRectToVisible:_searchBar.frame animated:NO];
		return NSNotFound;
	}
	return index;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
	return (![self isSearching] && indexPath.section == 0) ? 50 : [P7TrackCell rowHeight];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	if (![self isSearching] && indexPath.section == 0) {
		UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Shuffle"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Shuffle"];
		cell.textLabel.text = @"Shuffle";
		cell.textLabel.textColor = [P7Theme tintColor];
		cell.imageView.image = [P7Theme shuffleIcon];
		cell.imageView.tintColor = [P7Theme tintColor];
		return cell;
	}
	return [self trackCellForTrack:[self tracksInSection:indexPath.section][indexPath.row] number:0];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (![self isSearching] && indexPath.section == 0) {
		[[P7Player shared] shuffleTracks:_allTracks];
		return;
	}
	NSArray *tracks = [self isSearching] ? _results : _allTracks;
	P7Track *track = [self tracksInSection:indexPath.section][indexPath.row];
	NSUInteger index = [tracks indexOfObjectIdenticalTo:track];
	[self playTracks:tracks startIndex:index == NSNotFound ? 0 : index];
}

@end
