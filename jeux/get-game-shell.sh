#! /bin/bash

# Pour installer GameShell rapidement en formation : 
# Debian avec wget :
# wget -O - -q https://raw.githubusercontent.com/aaaaadrien/miscripts/refs/heads/main/jeux/get-game-shell.sh | bash
# S'il y a curl : 
# curl -s https://raw.githubusercontent.com/aaaaadrien/miscripts/refs/heads/main/jeux/get-game-shell.sh | bash

if [[ "$EUID" != 0 ]]
then
	echo "Lancer le script en root :-) Merci !"
fi

echo "Installation des prerequis"
apt update &> /dev/null
apt -y install gettext man-db procps psmisc nano tree ncal x11-apps wget &> /dev/null

echo "Creation d'un utilisateur dedie a GameShell"
if [[ $(grep -c 'gameshell:x:4242' /etc/passwd) != 1 ]]
then
	useradd -m -s /home/gameshell/gameshell.sh -u 4242 -N gameshell
fi

echo "Recuperation du jeu"
wget -O /home/gameshell/gameshell.sh -q https://github.com/phyver/GameShell/releases/download/latest/gameshell.sh 
chmod +x /home/gameshell/gameshell.sh

echo "Pour lancer le jeu : su - gameshell"
