#!/usr/bin/env python3

import requests
import json
import sys
import time
import base64
import configparser
import os
from datetime import datetime

# ==============================
# CHARGEMENT CONFIGURATION
# ==============================

CONFIG_FILE = 'image-generation.conf'

# Vérification de la présence du fichier
if not os.path.exists(CONFIG_FILE):
    print(f"Erreur : Le fichier '{CONFIG_FILE}' est introuvable.")
    print("Veuillez le créer avec la section [DEFAULT] appropriée.")
    sys.exit(1)

config = configparser.ConfigParser()
config.read(CONFIG_FILE)

try:
    settings = config['DEFAULT']

    API_BASE = settings.get('API_BASE')
    MODEL_NAME = settings.get('MODEL_NAME', 'sd')
    SIZE = settings.get('SIZE', '512x512')
    OUTPUT_DIR = settings.get('OUTPUT_DIR', '.')

except KeyError as e:
    print(f"Erreur de configuration : Clé manquante {e}")
    sys.exit(1)

# ==============================
# GEN LOOP
# ==============================

def generate_image(prompt):
    payload = {
        "model": MODEL_NAME,
        "prompt": prompt,
        "n": 1,
        "size": SIZE,
        "response_format": "b64_json"
    }

    start_time = time.perf_counter()

    response = requests.post(
        f"{API_BASE}/images/generations",
        headers={"Content-Type": "application/json"},
        json=payload,
        timeout=600
    )
    response.raise_for_status()

    data = response.json()
    b64_image = data.get('data', [{}])[0].get('b64_json')

    if not b64_image:
        print("Erreur : la réponse ne contient pas d'image (b64_json manquant).")
        return

    duration = time.perf_counter() - start_time

    filename = f"image-{datetime.now().strftime('%Y%m%d%H%M%S')}.png"
    filepath = os.path.join(OUTPUT_DIR, filename)

    with open(filepath, 'wb') as f:
        f.write(base64.b64decode(b64_image))

    print(f"Image enregistrée : {filepath}")
    print(f"Temps de génération : {duration:.2f}s")
    print("-" * 40 + "\n")


def chat():
    print(f"Stable-diffusion.cpp CLI - {MODEL_NAME} ({SIZE})")
    print(f"Endpoint : {API_BASE}")
    print("Tape un prompt pour générer une image, '/bye' pour quitter.\n")

    while True:
        try:
            user_input = input("> ").strip()

            if not user_input:
                continue
            if user_input.lower() in ("exit", "quit", "/bye"):
                print("Bye")
                break

            generate_image(user_input)

        except KeyboardInterrupt:
            print("\nBye")
            sys.exit(0)
        except requests.exceptions.ConnectionError:
            print(f"\nErreur : Impossible de se connecter à {API_BASE}")
        except requests.exceptions.HTTPError as e:
            print(f"\nErreur HTTP : {e}")
        except Exception as e:
            print(f"\nErreur : {e}")


if __name__ == "__main__":
    chat()
