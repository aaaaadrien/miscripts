#!/bin/bash

# Usage: ./morse.sh "TEXTE A JOUER"

FREQ=800       # fréquence du son en Hz
VOLUME=0.5     # volume de 0.0 (silence) à 1.0 (max)
DOT=0.1        # durée d'un point
DASH=0.3       # durée d'un tiret
ELEM_GAP=0.1   # silence entre éléments d'une même lettre
LETTER_GAP=0.3 # silence entre lettres
WORD_GAP=0.7   # silence entre mots

declare -A MORSE=(
  [A]=".-"    [B]="-..." [C]="-.-." [D]="-.."  [E]="."
  [F]="..-."  [G]="--."  [H]="...." [I]=".."   [J]=".---"
  [K]="-.−"  [L]=".-.." [M]="--"   [N]="-."   [O]="---"
  [P]=".--."  [Q]="--.-" [R]=".-."  [S]="..."  [T]="-"
  [U]="..-"   [V]="...-" [W]=".--"  [X]="-..-" [Y]="-.--"
  [Z]="--.."
  [0]="-----" [1]=".----" [2]="..---" [3]="...--" [4]="....-"
  [5]="....." [6]="-...." [7]="--..." [8]="---.." [9]="----."
  [.]=".-.-.-" [,]="--..--" [?]="..--.." [!]="-.-.--"
  [-]="-....-" [/]="-..-."  ["("]="-.--." [")"]="-.--.-"
  [&]=".-..." [@]=".--.-."  [=]="-...-"
)

play_tone() {
  play -q -n synth "$1" sin "$FREQ" vol "$VOLUME"
}

text=$(echo "$1" | tr '[:lower:]' '[:upper:]')

for (( i=0; i<${#text}; i++ )); do
  char="${text:$i:1}"

  if [[ "$char" == " " ]]; then
    sleep "$WORD_GAP"
    continue
  fi

  code="${MORSE[$char]}"

  if [[ -z "$code" ]]; then
    continue  # caractère non supporté, on l'ignore
  fi

  first_elem=true
  for (( j=0; j<${#code}; j++ )); do
    elem="${code:$j:1}"

    $first_elem || sleep "$ELEM_GAP"
    first_elem=false

    if [[ "$elem" == "." ]]; then
      play_tone "$DOT"
    elif [[ "$elem" == "-" ]]; then
      play_tone "$DASH"
    fi
  done

  sleep "$LETTER_GAP"
done
