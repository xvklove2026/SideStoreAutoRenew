// SPDX-License-Identifier: MIT
// Declarations adapted from Apelin's MIT-licensed preferences support header.
#pragma once
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
@class PSSpecifier;
typedef NS_ENUM(NSInteger, PSCellType) {
    PSGroupCell = 0, PSLinkCell = 1, PSLinkListCell = 2,
    PSListItemCell = 3, PSTitleValueCell = 4, PSSliderCell = 5,
    PSSwitchCell = 6, PSStaticTextCell = 7, PSEditTextCell = 8,
    PSSegmentCell = 9, PSGiantIconCell = 10, PSGiantCell = 11,
    PSSecureEditTextCell = 12, PSButtonCell = 13, PSEditTextViewCell = 14
};
@interface PSViewController : UIViewController
@end
@interface PSListController : PSViewController {
@protected
    NSMutableArray *_specifiers;
}
- (NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (NSArray *)specifiers;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
- (PSSpecifier *)specifierForID:(NSString *)identifier;
- (void)reloadSpecifier:(PSSpecifier *)specifier;
@end
@interface PSSpecifier : NSObject
@property(nonatomic, copy) NSString *name;
+ (instancetype)preferenceSpecifierNamed:(NSString *)name target:(id)target set:(SEL)set get:(SEL)get detail:(Class)detail cell:(PSCellType)cell edit:(Class)edit;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@end
