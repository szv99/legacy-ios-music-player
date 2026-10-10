#import "P7EntityCell.h"
#import "P7Theme.h"
#import "P7ImageCache.h"
#import "P7FadeImageView.h"

@implementation P7EntityCell {
	P7FadeImageView *_artworkView;
	UILabel *_titleLabel;
	UILabel *_detailLabel;
	BOOL _round;
	BOOL _plain;
}

+ (CGFloat)rowHeight {
	return 60;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
	if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier])) {
		self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
		_artworkView = [P7FadeImageView new];
		_artworkView.contentMode = UIViewContentModeScaleAspectFill;
		_artworkView.clipsToBounds = YES;
		[self.contentView addSubview:_artworkView];

		_titleLabel = [UILabel new];
		_titleLabel.font = [UIFont systemFontOfSize:16];
		[self.contentView addSubview:_titleLabel];

		_detailLabel = [UILabel new];
		_detailLabel.font = [UIFont systemFontOfSize:12];
		_detailLabel.textColor = [P7Theme secondaryTextColor];
		[self.contentView addSubview:_detailLabel];
		self.separatorInset = UIEdgeInsetsMake(0, 68, 0, 0);
	}
	return self;
}

- (void)layoutSubviews {
	[super layoutSubviews];
	CGFloat width = self.contentView.bounds.size.width;
	CGFloat height = self.contentView.bounds.size.height;
	_artworkView.frame = CGRectMake(15, (height - 44) / 2, 44, 44);
	_artworkView.layer.cornerRadius = _round ? 22 : 0;
	CGFloat x = _plain ? 15 : 68;
	if (_plain || !_detailLabel.text.length) {
		_titleLabel.frame = CGRectMake(x, 0, width - x - 4, height);
	} else {
		_titleLabel.frame = CGRectMake(x, 11, width - x - 4, 20);
		_detailLabel.frame = CGRectMake(x, 32, width - x - 4, 16);
	}
}

- (void)configureWithEntity:(P7Entity *)entity {
	_plain = NO;
	_round = entity.isArtist;
	_artworkView.hidden = NO;
	_titleLabel.text = entity.name;
	_titleLabel.textColor = [UIColor blackColor];
	_detailLabel.text = entity.subtitle;
	self.separatorInset = UIEdgeInsetsMake(0, 68, 0, 0);
	UIImage *placeholder = [P7Theme placeholderArtworkWithSize:44];
	[_artworkView p7_setCoverForTrackID:entity.coverKey size:88 placeholder:placeholder];
	[self setNeedsLayout];
}

- (void)configureWithTitle:(NSString *)title {
	_plain = YES;
	_artworkView.hidden = YES;
	_titleLabel.text = title;
	_titleLabel.textColor = [P7Theme tintColor];
	_detailLabel.text = nil;
	self.separatorInset = UIEdgeInsetsMake(0, 15, 0, 0);
	[self setNeedsLayout];
}

@end
