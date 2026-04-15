A Linux XFCE theme that replicates the Look and Feel of Windows Aero.

## Notice Regarding Microsoft-Related Assets

Microsoft, Windows, and Windows 7 are trademarks of Microsoft Corporation.
Any Microsoft-derived, Microsoft-referencing, or Microsoft-inspired assets remain the property of their respective owner and are not covered by this project's CC0 dedication.
The CC0 dedication applies only to original project material created by the author(s) and does not affect any copyright, trademark, or other rights held by Microsoft.
This project is unofficial and is not affiliated with, endorsed by, sponsored by, or approved by Microsoft.

## Project Status

Beta / WIP

This theme is still under active development.
Visual details, asset quality, compatibility, and behavior may change over time.

## Preview

<img width="1920" height="1080" alt="preview-1" src="https://github.com/user-attachments/assets/3ff09f05-bf1f-4a6b-9cdd-5048e844c5f0" />

## Tested and Compatible OS + XFCE Version

- Linux Mint 22.2 - XFCE 4.18
- Linux Mint 22.2 - XFCE 4.20

(Theme behavior may vary depending on the Linux distribution, XFCE version, compositor setup, and local GTK/XFWM configuration.)

## Manual Installation Guide

Download the `.zip` file at the ` <> Code ` Button and extract it to the local themes directory 
`/home/$USER/.themes`

Paste the `picom.conf` to the directory `/home/$USER/.config` and restart picom to apply the settings.

## Customizing the color and opacity of the menu, taskbar and window decorations.

- To change the color of window borders, the start menu, and the taskbar, you need to go to the theme folder where the script "xfce-color-switching-tool.sh" is located.
- Then, right-click on this shell script and go to "Properties."
- Click on the "Permissions" tab and check the box next to "Program" and "Allow this file to run as a program."
- After that, close the window, right-click on an empty area within the theme folder, and select "Open in Terminal."
- Enter the command "./xfce-color-switching-tool.sh" to start the script.
- / ! \ Please note that you must resize the window to at least 155x45px before starting the script, otherwise the program may not start or display errors may occur.

<img width="1889" height="1054" alt="preview-2" src="https://github.com/user-attachments/assets/5788eaae-55cb-4eaf-9397-319a31d34e7f" />

## License

Original code and original project material may be released under CC0, unless stated otherwise.

Microsoft-related names, branding, and any third-party assets are excluded from the CC0 dedication and remain subject to their respective legal rights.
