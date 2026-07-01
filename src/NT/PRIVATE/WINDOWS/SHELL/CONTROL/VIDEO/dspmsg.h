//
//  Values are 32 bit values layed out as follows:
//
//   3 3 2 2 2 2 2 2 2 2 2 2 1 1 1 1 1 1 1 1 1 1
//   1 0 9 8 7 6 5 4 3 2 1 0 9 8 7 6 5 4 3 2 1 0 9 8 7 6 5 4 3 2 1 0
//  +---+-+-+-----------------------+-------------------------------+
//  |Sev|C|R|     Facility          |               Code            |
//  +---+-+-+-----------------------+-------------------------------+
//
//  where
//
//      Sev - is the severity code
//
//          00 - Success
//          01 - Informational
//          10 - Warning
//          11 - Error
//
//      C - is the Customer code flag
//
//      R - is a reserved bit
//
//      Facility - is the facility code
//
//      Code - is the facility's status code
//
//
// Define the facility codes
//


//
// Define the severity codes
//


//
// MessageId: ID_DSP_TXT_WARNING
//
// MessageText:
//
//  WARNING!
//
#define ID_DSP_TXT_WARNING               0x00000001L

//
// MessageId: ID_DSP_TXT_COLOR
//
// MessageText:
//
//  %1!d! Colors
//
#define ID_DSP_TXT_COLOR                 0x00000002L

//
// MessageId: ID_DSP_TXT_CLOSE
//
// MessageText:
//
//  Close
//
#define ID_DSP_TXT_CLOSE                 0x00000003L

//
// MessageId: ID_DSP_TXT_OK
//
// MessageText:
//
//  OK
//
#define ID_DSP_TXT_OK                    0x00000004L

//
// MessageId: ID_DSP_TXT_INSTALL
//
// MessageText:
//
//  Install
//
#define ID_DSP_TXT_INSTALL               0x00000005L

//
// MessageId: ID_DSP_TXT_TRUECOLOR
//
// MessageText:
//
//  True Color
//
#define ID_DSP_TXT_TRUECOLOR             0x00000006L

//
// MessageId: ID_DSP_TXT_XBYY
//
// MessageText:
//
//  %1!d! by %2!d! pixels
//
#define ID_DSP_TXT_XBYY                  0x00000007L

//
// MessageId: ID_DSP_TXT_FREQ
//
// MessageText:
//
//  %1!d! Hertz
//
#define ID_DSP_TXT_FREQ                  0x00000008L

//
// MessageId: ID_DSP_TXT_COLOR_MODE
//
// MessageText:
//
//  %1!d! by %2!d! pixels, %3!d! Colors, %4!d! Hertz
//
#define ID_DSP_TXT_COLOR_MODE            0x00000009L

//
// MessageId: ID_DSP_TXT_TRUE_COLOR_MODE
//
// MessageText:
//
//  %1!d! by %2!d! pixels, True Color, %4!d! Hertz
//
#define ID_DSP_TXT_TRUE_COLOR_MODE       0x0000000AL

//
// MessageId: ID_DSP_TXT_COLOR_MODE_INT_REF
//
// MessageText:
//
//  %1!d! by %2!d! pixels, %3!d! Colors, %4!d! Hertz, Interlaced
//
#define ID_DSP_TXT_COLOR_MODE_INT_REF    0x0000000BL

//
// MessageId: ID_DSP_TXT_TRUE_COLOR_MODE_INT_REF
//
// MessageText:
//
//  %1!d! by %2!d! pixels, True Color, %4!d! Hertz, Interlaced
//
#define ID_DSP_TXT_TRUE_COLOR_MODE_INT_REF 0x0000000CL

//
// MessageId: ID_DSP_TXT_COLOR_MODE_DEF_REF
//
// MessageText:
//
//  %1!d! by %2!d! pixels, %3!d! Colors, Hardware default refresh
//
#define ID_DSP_TXT_COLOR_MODE_DEF_REF    0x0000000DL

//
// MessageId: ID_DSP_TXT_TRUE_COLOR_MODE_DEF_REF
//
// MessageText:
//
//  %1!d! by %2!d! pixels, True Color, Hardware default refresh
//
#define ID_DSP_TXT_TRUE_COLOR_MODE_DEF_REF 0x0000000EL

//
// MessageId: ID_DSP_TXT_INTERLACED
//
// MessageText:
//
//  %1!d! Hertz, Interlaced
//
#define ID_DSP_TXT_INTERLACED            0x0000000FL

//
// MessageId: ID_DSP_TXT_DEFFREQ
//
// MessageText:
//
//  Use hardware default setting
//
#define ID_DSP_TXT_DEFFREQ               0x00000010L

//
// MessageId: ID_DSP_TXT_COMPATABLE_DEV
//
// MessageText:
//
//  %1 compatible display adapter
//
#define ID_DSP_TXT_COMPATABLE_DEV        0x00000011L

//
// MessageId: ID_DSP_TXT_OLD_DRIVER
//
// MessageText:
//
//  %n%n
//  You are using a down-level graphics driver.
//  Please contact the manufacturer to get an updated driver.
//
#define ID_DSP_TXT_OLD_DRIVER            0x00000012L

//
// MessageId: ID_DSP_TXT_INVALID_DATA
//
// MessageText:
//
//  The application got invalid data from the display driver. %1
//
#define ID_DSP_TXT_INVALID_DATA          0x00000013L

//
// MessageId: ID_DSP_TXT_CANTPREVIEW
//
// MessageText:
//
//  The display mode chosen can not be previewed. %1
//
#define ID_DSP_TXT_CANTPREVIEW           0x00000014L

//
// MessageId: ID_DSP_TXT_MODE_UNTESTED
//
// MessageText:
//
//  You have not tried these new settings successfully. Please press the
//  Test button to preview this new graphics mode.
//
#define ID_DSP_TXT_MODE_UNTESTED         0x00000015L

//
// MessageId: ID_DSP_TXT_MODE_UNTESTED_RESTART
//
// MessageText:
//
//  You have not tried these new settings successfully. Please press the
//  Test button to preview this new graphics mode.
//  If you want to keep this selection anyway, choose OK.
//
#define ID_DSP_TXT_MODE_UNTESTED_RESTART 0x00000016L

//
// MessageId: ID_DSP_TXT_BAD_INF
//
// MessageText:
//
//  The specified .INF file could not be found.
//
#define ID_DSP_TXT_BAD_INF               0x00000017L

//
// MessageId: ID_DSP_TXT_OLD_INF
//
// MessageText:
//
//  You are using a down-level installation disk.
//  It is recommended you contact the manufacturer to get an updated driver.
//
#define ID_DSP_TXT_OLD_INF               0x00000018L

//
// MessageId: ID_DSP_TXT_MISSING_INF
//
// MessageText:
//
//  The VIDEO.INF file is missing. No font or driver selections are
//  available.
//
#define ID_DSP_TXT_MISSING_INF           0x00000019L

//
// MessageId: ID_DSP_TXT_CHANGE_FONT
//
// MessageText:
//
//  Change System Font
//
#define ID_DSP_TXT_CHANGE_FONT           0x0000001AL

//
// MessageId: ID_DSP_TXT_FONT_IN_SETUP_MODE
//
// MessageText:
//
//  The font size cannot be changed during Setup.
//  To change the font size, use the Display option in Control Panel after
//  installing Windows NT.
//
#define ID_DSP_TXT_FONT_IN_SETUP_MODE    0x0000001BL

//
// MessageId: ID_DSP_TXT_FONT_LATER
//
// MessageText:
//
//  Changes in the system font will only take effect after the fonts have been
//  installed and Windows NT has been restarted.
//
#define ID_DSP_TXT_FONT_LATER            0x0000001CL

//
// MessageId: ID_DSP_TXT_NEW_FONT
//
// MessageText:
//
//  You have selected a new system font size.
//  Are you sure you want to change the system font size and install new fonts?
//
#define ID_DSP_TXT_NEW_FONT              0x0000001DL

//
// MessageId: ID_DSP_TXT_CHANGE_SETTINGS
//
// MessageText:
//
//  Change Settings.
//
#define ID_DSP_TXT_CHANGE_SETTINGS       0x0000001EL

//
// MessageId: ID_DSP_TXT_ADMIN_CHANGE
//
// MessageText:
//
//  You do not have the required Administrative privilege to change these
//  system settings. Please contact your Administrator.
//
#define ID_DSP_TXT_ADMIN_CHANGE          0x0000001FL

//
// MessageId: ID_DSP_TXT_DID_TEST_WARNING
//
// MessageText:
//
//  The new mode will be tested.
//  Your graphics adapter will be set to the new mode temporarily so you can
//  determine whether it works properly.
//  Please press OK and then wait 5 seconds.
//
#define ID_DSP_TXT_DID_TEST_WARNING      0x00000020L

//
// MessageId: ID_DSP_TXT_TEST_MODE
//
// MessageText:
//
//  Testing Mode
//
#define ID_DSP_TXT_TEST_MODE             0x00000021L

//
// MessageId: ID_DSP_TXT_DID_TEST_RESULT
//
// MessageText:
//
//  Did you see the test bitmap properly?
//
#define ID_DSP_TXT_DID_TEST_RESULT       0x00000022L

//
// MessageId: ID_DSP_TXT_TEST_FAILED
//
// MessageText:
//
//  The screen was not visible due to a limitation of your video card or display
//  monitor.
//  Please try different settings for your display.
//
#define ID_DSP_TXT_TEST_FAILED           0x00000023L

//
// MessageId: ID_DSP_TXT_ADMIN_INSTALL
//
// MessageText:
//
//  Windows NT Setup has not changed the requested settings.
//  You may not have the required Administrative privilege to install or
//  deinstall new files or drivers.
//  Please contact your Administrator.
//
#define ID_DSP_TXT_ADMIN_INSTALL         0x00000024L

//
// MessageId: ID_DSP_TXT_FAIL_LOAD
//
// MessageText:
//
//  The driver could not be started dynamically.
//  Please restart Windows NT to run with the new driver.
//
#define ID_DSP_TXT_FAIL_LOAD             0x00000025L

//
// MessageId: ID_DSP_TXT_MISSING_LOAD_PRIV
//
// MessageText:
//
//  %1%n%n
//  You do not have the Load Driver privilege which is required to start
//  device drivers dynamically.
//
#define ID_DSP_TXT_MISSING_LOAD_PRIV     0x00000026L

//
// MessageId: ID_DSP_TXT_INSTALL_DRIVER
//
// MessageText:
//
//  Installing Driver
//
#define ID_DSP_TXT_INSTALL_DRIVER        0x00000027L

//
// MessageId: ID_DSP_TXT_DRIVER_IN_SETUP_MODE
//
// MessageText:
//
//  The driver cannot be changed during Setup.
//  To change the driver, use the Display option in Control Panel after
//  installing Windows NT.
//
#define ID_DSP_TXT_DRIVER_IN_SETUP_MODE  0x00000028L

//
// MessageId: ID_DSP_TXT_AUTODETECT
//
// MessageText:
//
//  WARNING! This option will attempt to install all the video drivers so that your graphics
//  adapter can be detected. You will then need to reboot your machine so
//  that drivers can detect the adapter. %1
//
#define ID_DSP_TXT_AUTODETECT            0x00000029L

//
// MessageId: ID_DSP_TXT_AUTODETECT_PROCEED
//
// MessageText:
//
//  %n%n
//  Do you want to proceed with detection?
//
#define ID_DSP_TXT_AUTODETECT_PROCEED    0x0000002AL

//
// MessageId: ID_DSP_TXT_INSTALL_WARN
//
// MessageText:
//
//  This operation will change your system configuration. Do you want to proceed
//  anyway?
//
#define ID_DSP_TXT_INSTALL_WARN          0x0000002BL

//
// MessageId: ID_DSP_TXT_DRIVER_INSTALLED
//
// MessageText:
//
//  The drivers were successfully installed.
//
#define ID_DSP_TXT_DRIVER_INSTALLED      0x0000002CL

//
// MessageId: ID_DSP_TXT_DEINSTALL_DRIVER
//
// MessageText:
//
//  Deinstalling Driver
//
#define ID_DSP_TXT_DEINSTALL_DRIVER      0x0000002DL

//
// MessageId: ID_DSP_TXT_DRIVER_DEINSTALLED
//
// MessageText:
//
//  The drivers were successfully deinstalled.
//
#define ID_DSP_TXT_DRIVER_DEINSTALLED    0x0000002EL

//
// MessageId: ID_DSP_TXT_SETTINGS
//
// MessageText:
//
//  Display Settings
//
#define ID_DSP_TXT_SETTINGS              0x0000002FL

//
// MessageId: ID_DSP_TXT_SETUP_SAVE
//
// MessageText:
//
//  To save the settings you have just tested and continue with Setup,
//  press the OK button in the Display Settings window.
//
#define ID_DSP_TXT_SETUP_SAVE            0x00000030L

