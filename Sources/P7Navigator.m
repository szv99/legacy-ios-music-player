#import "P7Navigator.h"
#import "P7ArtistViewController.h"
#import "P7PlaylistViewController.h"
#import "P7API.h"
#import "P7Blocks.h"

@implementation P7Navigator

+ (UIViewController *)controllerForEntity:(P7Entity *)entity {
	if (entity.isArtist) return [[P7ArtistViewController alloc] initWithEntity:entity];
	return [[P7PlaylistViewController alloc] initWithEntity:entity];
}

+ (void)push:(UIViewController *)page from:(UIViewController *)controller {
	UINavigationController *own = controller.navigationController;
	if (own && !own.presentingViewController) {
		[own pushViewController:page animated:YES];
		return;
	}
	// Presented modally (Now Playing, queue): go back to the tabs and push there.
	UIViewController *root = (controller.view.window ?: [UIApplication sharedApplication].keyWindow).rootViewController;
	UINavigationController *nav = nil;
	if ([root isKindOfClass:[UITabBarController class]]) {
		id selected = [(UITabBarController *)root selectedViewController];
		if ([selected isKindOfClass:[UINavigationController class]]) nav = selected;
	}
	[root dismissViewControllerAnimated:YES completion:nil];
	[nav pushViewController:page animated:NO];
}

+ (void)openEntity:(P7Entity *)entity from:(UIViewController *)controller {
	if (!entity.entityID.length) return;
	[self push:[self controllerForEntity:entity] from:controller];
}

+ (void)openArtistOfTrack:(P7Track *)track from:(UIViewController *)controller {
	[UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
	[[P7API shared] fetchArtistsForTrack:track completion:^(NSArray *artists, NSError *error) {
		[UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
		if (error || !artists.count) {
			if (error) [P7Alert showError:error title:@"Couldn't Find the Artist"];
			else [P7Alert showMessage:@"No artist page for this song." title:track.artist];
			return;
		}
		if (artists.count == 1) {
			[self openEntity:artists.firstObject from:controller];
			return;
		}
		P7ActionSheet *sheet = [[P7ActionSheet alloc] initWithTitle:@"Go to Artist"];
		for (P7Entity *artist in artists) {
			NSString *title = [artist.subtitle isEqualToString:@"Channel"] ? [artist.name stringByAppendingString:@" (channel)"] : artist.name;
			[sheet addButton:title handler:^{ [self openEntity:artist from:controller]; }];
		}
		[sheet showFrom:controller];
	}];
}

+ (void)openAlbumOfTrack:(P7Track *)track from:(UIViewController *)controller {
	if (!track.albumID) return;
	[self openEntity:[P7Entity entityWithID:track.albumID name:track.album kind:@"album"] from:controller];
}

@end
