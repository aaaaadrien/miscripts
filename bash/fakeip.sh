#! /bin/bash

echo "Génération IPv4 publique impossible :"
for i in 1 2 3 4 5
do
	o1=$((RANDOM % 255))
	o2=$((256 + RANDOM % 44)) # Octet "Hollywood" (256-299)
	o3=$((RANDOM % 255))
	o4=$((RANDOM % 255))
	ips=($o1 $o2 $o3 $o4)
	# Mélange l'ordre pour que l'octet spécial change de place (ex: 289.x.x.x ou x.x.289.x)
	shuffled=($(printf "%s\n" "${ips[@]}" | shuf))
	echo "${shuffled[0]}.${shuffled[1]}.${shuffled[2]}.${shuffled[3]}"
done

echo ""
echo "Generation IPv4 publique réservée à la doc :"

for i in 1 2 3 4 5
do
        # https://www.rfc-editor.org/rfc/rfc5737
        case $((RANDOM % 3)) in
            0) echo "198.51.100.$((RANDOM % 256))" ;; # 198.51.100.0/24
            1) echo "203.0.113.$((RANDOM % 256))" ;; # 203.0.113.0/24
            2) echo "192.0.2.$((RANDOM % 256))" ;; # 192.0.2.0/24
        esac
done


echo ""
echo "Generation IPv6 publique réservée à la doc (pas trop longue) :"

for i in 1 2 3 4 5
do
        # https://www.rfc-editor.org/rfc/rfc3849 + https://www.rfc-editor.org/rfc/rfc4291 + https://www.rfc-editor.org/rfc/rfc9637
        case $((RANDOM % 2)) in
		0) echo "3fff:$(printf ':%04x:%04x:%04x:%04x:%04x' $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)))" ;; # 3fff::/20
		1) echo "2001:db8:$(printf ':%04x:%04x:%04x:%04x' $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)))" ;; # 2001:db8::/32
        esac
done

echo ""
echo "Generation IPv6 publique réservée à la doc (entière) :"

for i in 1 2 3 4 5
do
        # https://www.rfc-editor.org/rfc/rfc3849 + https://www.rfc-editor.org/rfc/rfc4291 + https://www.rfc-editor.org/rfc/rfc9637
        case $((RANDOM % 2)) in
                0) echo "3fff:$(printf '%04x:%04x:%04x:%04x:%04x:%04x:%04x' $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)))" ;; # 3fff::/20
                1) echo "2001:0db8:$(printf '%04x:%04x:%04x:%04x:%04x:%04x' $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)))" ;; # 2001:db8::/32
        esac
done
