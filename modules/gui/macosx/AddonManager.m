/*****************************************************************************
 * AddonManager.m: Addons manager for the Mac
 ****************************************************************************
 * Copyright (C) 2014 VideoLAN and authors
 * Author:       Felix Paul Kühne <fkuehne # videolan.org>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/

#import "AddonManager.h"

#import <vlc_common.h>
#import <vlc_events.h>
#import <vlc_addons.h>
#import "intf.h"

@interface VLCAddonManager ()
{
    addons_manager_t *_manager;
    NSMutableArray *_addons;
    NSArray *_displayedAddons;
}

- (void)addAddon:(addon_entry_t *)data;
- (void)discoveryEnded;
- (void)addonChanged:(addon_entry_t *)data;
@end

static void addonsEventsCallback( const vlc_event_t *, void * );

static void addonsEventsCallback( const vlc_event_t *event, void *data )
{
    if (event->type == vlc_AddonFound)
        [[VLCAddonManager sharedInstance] addAddon:event->u.addon_generic_event.p_entry];
    else if (event->type == vlc_AddonsDiscoveryEnded)
        [[VLCAddonManager sharedInstance] discoveryEnded];
    else if (event->type == vlc_AddonChanged)
        [[VLCAddonManager sharedInstance] addonChanged:event->u.addon_generic_event.p_entry];
}

@implementation VLCAddonManager

static VLCAddonManager *_o_sharedInstance = nil;

+ (VLCAddonManager *)sharedInstance
{
    return _o_sharedInstance ? _o_sharedInstance : [[self alloc] init];
}

#pragma mark - object handling

- (id)init
{
    if (_o_sharedInstance)
        [self dealloc];
    else {
        _o_sharedInstance = [super init];
        _addons = [[NSMutableArray alloc] init];
    }

    return _o_sharedInstance;
}

- (void)dealloc
{
    [_addons release];
    [_displayedAddons release];
    if ( _manager )
        addons_manager_Delete(_manager);
    [super dealloc];
}

#pragma mark - UI handling

- (void)awakeFromNib
{
    [_typeSwitcher removeAllItems];
    [_typeSwitcher addItemWithTitle:_NS("All")];
    [[_typeSwitcher lastItem] setTag: -1];
    [_typeSwitcher addItemWithTitle:_NS("Skins")];
    [[_typeSwitcher lastItem] setTag:ADDON_SKIN2];
    [_typeSwitcher addItemWithTitle:_NS("Playlist parsers")];
    [[_typeSwitcher lastItem] setTag:ADDON_PLAYLIST_PARSER];
    [_typeSwitcher addItemWithTitle:_NS("Service discovery")];
    [[_typeSwitcher lastItem] setTag:ADDON_SERVICE_DISCOVERY];
    [_typeSwitcher addItemWithTitle:_NS("Extensions")];
    [[_typeSwitcher lastItem] setTag:ADDON_EXTENSION];

    [_localAddonsOnlyCheckbox setTitle:_NS("Show Installed Only")];
    [_localAddonsOnlyCheckbox setState:NSOffState];
    [_spinner setUsesThreadedAnimation:YES];

    [_window setTitle:_NS("Addon Manager")];

    [[[_addonsTable tableColumnWithIdentifier:@"installed"] headerCell] setStringValue:_NS("Installed")];
    [[[_addonsTable tableColumnWithIdentifier:@"name"] headerCell] setStringValue:_NS("Name")];
    [[[_addonsTable tableColumnWithIdentifier:@"author"] headerCell] setStringValue:_NS("Author")];
    [[[_addonsTable tableColumnWithIdentifier:@"type"] headerCell] setStringValue:_NS("Type")];

    _manager = addons_manager_New((vlc_object_t *)VLCIntf);
    if (!_manager)
        return;

    vlc_event_manager_t *p_em = _manager->p_event_manager;
    vlc_event_attach(p_em, vlc_AddonFound, addonsEventsCallback, self);
    vlc_event_attach(p_em, vlc_AddonsDiscoveryEnded, addonsEventsCallback, self);
    vlc_event_attach(p_em, vlc_AddonChanged, addonsEventsCallback, self);
}

- (void)showWindow
{
    [self _findNewAddons];
    [_spinner startAnimation:nil];
    [_window makeKeyAndOrderFront:nil];
}

- (IBAction)switchType:(id)sender
{
    [self _refactorDataModel];
}

- (IBAction)toggleLocalCheckbox:(id)sender
{
    [self _refactorDataModel];
}

- (IBAction)tableAction:(id)sender
{
    NSInteger clickedRow = [_addonsTable clickedRow];
    if (clickedRow > _displayedAddons.count - 1 || clickedRow < 0)
        return;

    NSDictionary *currentItem = _displayedAddons[clickedRow];

    if ([[currentItem objectForKey:@"state"] intValue] == ADDON_INSTALLED)
        [self _removeAddonWithID:[[currentItem objectForKey:@"uuid"] pointerValue]];
    else
        [self _installAddonWithID:[[currentItem objectForKey:@"uuid"] pointerValue]];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)aTableView
{
    return [_displayedAddons count];
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex
{
    NSString *identifier = [aTableColumn identifier];
    if ([identifier isEqualToString:@"installed"]) {
        if ([[_displayedAddons[rowIndex] objectForKey:@"state"] intValue] == ADDON_INSTALLED)
            return @"✔";
        return @"✘";
    } else if([identifier isEqualToString:@"type"])
        return [self _getAddonType:[[_displayedAddons[rowIndex] objectForKey:@"type"] intValue]];

    return [_displayedAddons[rowIndex] objectForKey:identifier];
}

#pragma mark - data handling

- (void)addAddon:(addon_entry_t *)p_entry
{
    @autoreleasepool {
        NSString *name = [NSString stringWithUTF8String:p_entry->psz_name ? p_entry->psz_name : ""];
        if (p_entry->e_state == ADDON_INSTALLED)
            name = [name stringByAppendingFormat: @" (%@)", _NS("installed")];

        NSDictionary *addonProperties = [NSDictionary dictionaryWithObjectsAndKeys:
                                         name, @"name",
                                         [NSString stringWithUTF8String:p_entry->psz_description ? p_entry->psz_description : ""], @"description",
                                         [NSString stringWithUTF8String:p_entry->psz_author ? p_entry->psz_author : ""], @"author",
                                         [NSString stringWithUTF8String:p_entry->psz_source_uri ? p_entry->psz_source_uri : ""], @"uri",
                                         [NSString stringWithUTF8String:p_entry->psz_version ? p_entry->psz_version : ""], @"version",
                                         [NSString stringWithUTF8String:p_entry->psz_image_uri ? p_entry->psz_image_uri : ""], @"imageuri",
                                         [NSNumber numberWithInt:p_entry->e_state], @"state",
                                         [NSNumber numberWithInt:p_entry->e_type], @"type",
                                         [NSValue valueWithPointer:&p_entry->uuid], @"uuid",
                                         nil];
        [_addons addObject:addonProperties];
    }
}

- (void)discoveryEnded
{
    [self _refactorDataModel];
    [_spinner stopAnimation:nil];
}

- (void)addonChanged:(addon_entry_t *)data
{
    [self _refactorDataModel];
}

#pragma mark - helpers

- (void)_refactorDataModel
{
    BOOL installedOnly = _localAddonsOnlyCheckbox.state == NSOnState;
    int type = [[_typeSwitcher selectedItem] tag];

    NSUInteger count = _addons.count;
    NSMutableArray *filteredItems = [[NSMutableArray alloc] initWithCapacity:count];
    NSDictionary *currentItem;
    for (NSUInteger x = 0; x < count; x++) {
        currentItem = _addons[x];
        if (type != -1) {
            if ([[currentItem objectForKey:@"type"] intValue] == type) {
                if (installedOnly) {
                    if ([[currentItem objectForKey:@"state"] intValue] == ADDON_INSTALLED)
                        [filteredItems addObject:currentItem];
                } else
                    [filteredItems addObject:currentItem];
            }
        } else {
            if (installedOnly) {
                if ([[currentItem objectForKey:@"state"] intValue] == ADDON_INSTALLED)
                    [filteredItems addObject:currentItem];
            } else
                [filteredItems addObject:currentItem];
        }
    }

    if (_displayedAddons)
        [_displayedAddons release];
    _displayedAddons = [NSArray arrayWithArray:filteredItems];
    [_displayedAddons retain];
    [_addonsTable reloadData];
}

- (void)_findNewAddons
{
    addons_manager_Gather(_manager, NULL);
}

/* FIXME: un-used */
- (void)_findDesignatedAddon:(NSString *)uri
{
    addons_manager_Gather(_manager, [uri UTF8String]);
}

/* FIXME: un-used */
- (void)_findInstalled
{
    addons_manager_LoadCatalog(_manager);
}

- (void)_installAddonWithID:(addon_uuid_t)addonid
{
    addons_manager_Install(_manager, addonid);
}

- (void)_removeAddonWithID:(addon_uuid_t)addonid
{
    addons_manager_Remove(_manager, addonid);
}

- (NSString *)_getAddonType:(int)i_type
{
    switch (i_type)
    {
        case ADDON_SKIN2:
            return @"Skins";
        case ADDON_PLAYLIST_PARSER:
            return @"Playlist parsers";
        case ADDON_SERVICE_DISCOVERY:
            return @"Service Discovery";
        case ADDON_EXTENSION:
            return @"Extensions";
        default:
            return @"Unknown";
    }
}

@end