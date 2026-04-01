# APT MQTT Daemon

Ce projet fournit un démon Bash qui surveille les mises à jour APT disponibles et expose cet état via MQTT pour Home Assistant.

Le démon publie :

- une entité Home Assistant de type update via MQTT Discovery ;
- un état périodique avec les paquets upgradables ;
- une commande MQTT permettant de lancer une mise à jour APT à distance.

## Structure

- apt_mqtt_daemon.sh : boucle principale du démon.
- libs/config.sh : chargement de la configuration et calcul des topics MQTT.
- libs/mqtt.sh : publication MQTT et payload de discovery Home Assistant.
- libs/apt.sh : interrogation APT et exécution des mises à jour.
- libs/state.sh : persistance de la version installée dans state.json.
- libs/tools.sh : utilitaires génériques.
- config.conf.example : exemple de configuration.
- apt-mqtt.service : unité systemd d'exemple.
- install_service.sh : installe ou supprime l'unité systemd avec les bons chemins.

## Dépendances

Paquets système requis sur Debian/Ubuntu :

```bash
sudo apt update
sudo apt install -y mosquitto-clients jq
```

## Configuration

Le démon cherche un fichier de configuration dans cet ordre :

1. chemin explicite via APT_MQTT_CONFIG
2. /etc/apt_mqtt/config.conf
3. $HOME/.config/apt_mqtt/config.conf
4. ./config.conf

Exemple :

```bash
cp config.conf.example config.conf
chmod 600 config.conf
```

Variables principales :

- MQTT_BROKER : hôte du broker MQTT.
- MQTT_PORT : port du broker.
- MQTT_USERNAME / MQTT_PASSWORD : authentification éventuelle.
- MQTT_BASE_TOPIC : racine des topics publiés.
- OBJECT_ID : identifiant de l'entité Home Assistant.
- CHECK_INTERVAL : délai entre deux publications d'état.

Le hostname est normalisé puis ajouté automatiquement au topic de base.

## Exécution

Exécution manuelle :

```bash
chmod +x apt_mqtt_daemon.sh
sudo ./apt_mqtt_daemon.sh
```

Installation en service systemd :

```bash
sudo ./install_service.sh install
```

Installation puis suivi live du service :

```bash
sudo ./install_service.sh install -f
```

Avec un fichier de configuration spécifique :

```bash
sudo ./install_service.sh install --config /chemin/vers/config.conf
```

Voir l'état du service plus tard :

```bash
sudo ./install_service.sh status
sudo ./install_service.sh status -f
```

Suppression du service :

```bash
sudo ./install_service.sh remove
```

## MQTT exposé

Pour un hostname sanitizé my-host et MQTT_BASE_TOPIC=apt-update :

- état : apt-update/my-host/state
- attributs : apt-update/my-host/attributes
- commandes : apt-update/my-host/command
- disponibilité : apt-update/my-host/availability

Commandes acceptées sur le topic de commande :

- install, update, upgrade : lance apt-get update puis apt-get -y dist-upgrade
- dry-run, simulate : simulation sans changement
- check, status : republie l'état immédiatement

## Documentation détaillée

Voir [docs/fonctionnement.md](docs/fonctionnement.md) pour le fonctionnement interne, le format des messages et les choix de structure.

