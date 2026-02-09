#!/usr/bin/env python3

import requests
import json
import sys
import time
import configparser
import os

# ==============================
# CHARGEMENT CONFIGURATION
# ==============================

CONFIG_FILE = 'chat-llm.conf'

# Vérification de la présence du fichier
if not os.path.exists(CONFIG_FILE):
    print(f"Erreur : Le fichier '{CONFIG_FILE}' est introuvable.")
    print("Veuillez le créer avec les sections [DEFAULT] appropriées.")
    sys.exit(1)

config = configparser.ConfigParser()
config.read(CONFIG_FILE)

try:
    settings = config['DEFAULT']
    
    VLLM_API_BASE = settings.get('VLLM_API_BASE')
    MODEL_NAME = settings.get('MODEL_NAME')
    SYSTEM_PROMPT = settings.get('SYSTEM_PROMPT', "Tu es un assistant utile, clair et concis.")
    # On convertit en entier car le fichier conf renvoie des chaînes
    MAX_HISTORY = int(settings.get('MAX_HISTORY', 10))

except KeyError as e:
    print(f"Erreur de configuration : Clé manquante {e}")
    sys.exit(1)
except ValueError:
    print("Erreur : MAX_HISTORY doit être un nombre entier.")
    sys.exit(1)

# ==============================
# CHAT LOOP
# ==============================

def chat():
    print(f"Chat CLI - {MODEL_NAME}")
    print(f"Endpoint : {VLLM_API_BASE}")
    print("Tape '/bye' pour quitter ou 'clear' pour réinitialiser.\n")

    system_prompt = {"role": "system", "content": SYSTEM_PROMPT}
    messages = [system_prompt]

    while True:
        try:
            user_input = input("> ").strip()
            
            if not user_input: continue
            if user_input.lower() in ("exit", "quit", "/bye"):
                print("Bye"); break
            if user_input.lower() == "clear":
                messages = [system_prompt]
                print("Historique effacé.\n"); continue

            messages.append({"role": "user", "content": user_input})

            payload = {
                "model": MODEL_NAME,
                "messages": messages,
                "temperature": 0.7,
                "max_tokens": 1024,
                "stream": True 
            }

            start_time = time.perf_counter()
            first_token_time = None

            response = requests.post(
                f"{VLLM_API_BASE}/chat/completions",
                headers={"Content-Type": "application/json"},
                json=payload,
                stream=True,
                timeout=300
            )
            response.raise_for_status()

            print("\n>> ", end="", flush=True)
            full_assistant_msg = ""

            for line in response.iter_lines():
                if line:
                    line_data = line.decode('utf-8').removeprefix('data: ')
                    if line_data == '[DONE]': break
                    
                    try:
                        chunk = json.loads(line_data)
                        content = chunk['choices'][0]['delta'].get('content', '')
                        
                        if content and first_token_time is None:
                            first_token_time = time.perf_counter()
                        
                        print(content, end="", flush=True)
                        full_assistant_msg += content
                    except json.JSONDecodeError:
                        continue

            end_time = time.perf_counter()
            total_duration = end_time - start_time
            ttft = (first_token_time - start_time) if first_token_time else 0

            print(f"\n\nTemps total : {total_duration:.2f}s | TTFT : {ttft:.2f}s")
            print("-" * 40 + "\n")

            messages.append({"role": "assistant", "content": full_assistant_msg})

            if len(messages) > MAX_HISTORY:
                messages = [system_prompt] + messages[-(MAX_HISTORY-1):]

        except KeyboardInterrupt:
            print("\nBye"); sys.exit(0)
        except requests.exceptions.ConnectionError:
            print(f"\nErreur : Impossible de se connecter à {VLLM_API_BASE}")
        except Exception as e:
            print(f"\nErreur : {e}")

if __name__ == "__main__":
    chat()
