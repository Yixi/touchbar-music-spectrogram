//
//  TouchBarSpectrum-Bridging-Header.h
//
//  Declares the private AppKit Touch Bar SPI used to host a persistent
//  control-strip item and to present a full-width system-modal Touch Bar.
//  These methods exist in AppKit at runtime but are absent from the public
//  SDK headers, so we redeclare them here. They resolve through the Objective-C
//  runtime against the already-linked AppKit — no extra linking required.
//
//  The private *C* functions from DFRFoundation are NOT declared here; they are
//  resolved at runtime via dlopen/dlsym in DFRBridge.swift to avoid a link-time
//  dependency on a private framework.
//

#import <AppKit/AppKit.h>

@interface NSTouchBarItem (TBSPrivateSPI)
/// Installs an item into the system Touch Bar tray (control strip region).
+ (void)addSystemTrayItem:(NSTouchBarItem *)item;
/// Removes a previously installed system-tray item.
+ (void)removeSystemTrayItem:(NSTouchBarItem *)item;
@end

@interface NSTouchBar (TBSPrivateSPI)
/// Presents a Touch Bar modally over the control strip.
/// placement 0 == the app region beside the control strip (~685pt usable).
/// placement 1 == full-width takeover (~1085pt).
+ (void)presentSystemModalTouchBar:(NSTouchBar *)touchBar
                         placement:(long long)placement
          systemTrayItemIdentifier:(NSTouchBarItemIdentifier)identifier;
+ (void)minimizeSystemModalTouchBar:(NSTouchBar *)touchBar;
+ (void)dismissSystemModalTouchBar:(NSTouchBar *)touchBar;
@end
