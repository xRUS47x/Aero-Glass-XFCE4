A Linux XFCE theme that replicates the Look and Feel of Windows Aero.

## Preview


<img width="1920" height="1080" alt="Aero" src="https://github.com/user-attachments/assets/b56f4085-5312-4406-adf1-ac23abcf18ee" />


## Compatible OS + XFCE Version

- Linux Mint 22.2 - XFCE 4.18

(The theme's functionality may vary depending on the Distribution and XFCE version. Please keep in Mind that this theme is currently W.I.P!)

## Manual Installation Guide

Download the `.zip` file at the ` <> Code ` Button and extract it to the local themes directory 
`/home/$USER/.themes`

Paste the `picom.conf` to the directory `/home/$USER/.config` and restart picom to apply the settings.

## Customizing the color + opacity of the taskbar and whisker menu

Navigate to ".../gtk-3.0/widgets/aero-elements.css" in the theme folder

and change the second line to the code "@define-color panel_base #XXX;" Add your desired color after the hashtag by using the HTML color code.

To change the opacity, you need to change the values ​​in
  "linear-gradient(alpha(@edge_dark, 0.75), alpha(@edge_dark, 0.75)),
  linear-gradient(alpha(@edge_light, 0.75), alpha(@edge_light, 0.75)),
  linear-gradient(alpha(@panel_base, 0.75), alpha(@panel_base, 0.75));"
from 0.75 to any other value. To change the opacity of the whisker menu, you need to manually adjust the background opacity in the whisker menu settings.
