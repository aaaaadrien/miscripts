#! /bin/bash

BRANCH=$1
if [[ ! $BRANCH =~ [0-9]+.[0-9]+ ]]
then
	BRANCH=$(uname -r | grep -Eo '(^[0-9]+.[0-9]+)')
fi

echo Recherche kernel branche : "$BRANCH"
koji list-builds --package=kernel --pattern "kernel-$BRANCH.*$(rpm -E %fedora)"

TRYTOGET=$(koji list-builds --package=kernel --pattern "kernel-$BRANCH.*$(rpm -E %fedora)" | tail -1 | awk '{ print $1; }')


echo -e "\n\n"
echo "Noyau actuel ....... : kenrnel-$(uname -r)"
echo "Noyau à installer .. : $TRYTOGET.$(uname -m)"
read -r -p "Tenter l'installation de la dernière version détectée ? " REPONSE

if [[ $REPONSE == "y" ]]
then
	mkdir /var/tmp/kerneltest/
	cd /var/tmp/kerneltest/ || exit
	rm -rf /var/tmp/kerneltest/*rpm
	koji download-build --arch="$(uname -m)" "$TRYTOGET"
	sudo dnf update kernel-*.rpm
fi





