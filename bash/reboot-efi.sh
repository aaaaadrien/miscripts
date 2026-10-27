#!/bin/bash

efibootmgr | awk '{ print $1 " " $2;}'

read -p "Numéro de l'entrée à rebooter (Ex 0005) : " bootnumber

efibootmgr --bootnext $bootnumber && systemctl reboot
