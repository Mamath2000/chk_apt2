# APT MQTT Daemon

Ce projet fournit deux démons Bash séparés :

- apt_mqtt_daemon.sh pour surveiller les mises à jour APT et piloter le self-update du dépôt.
- docker_mqtt_daemon.sh pour exposer les mises à jour Docker Compose via MQTT pour Home Assistant.

Le daemon APT publie :

- une entité Home Assistant de type update via MQTT Discovery ;
- un état périodique avec les paquets upgradables ;
- une commande MQTT permettant de lancer une mise à jour APT à distance.

Le daemon Docker publie un device principal Docker MQTT et, pour chaque hôte, un device qui regroupe toutes les stacks docker-compose détectées.

## Structure

- apt_mqtt_daemon.sh : boucle principale du démon APT.
- docker_mqtt_daemon.sh : boucle principale du démon Docker Compose.
- libs/config.sh : chargement de la configuration et calcul des topics MQTT.
- libs/mqtt.sh : publication MQTT et payload de discovery Home Assistant.
- libs/apt.sh : interrogation APT et exécution des mises à jour.
- libs/docker.sh : détection des stacks Docker Compose, résolution des digests d'images et mise à jour des stacks.
- libs/git.sh : mise à jour du dépôt et redémarrage du service.
- libs/state.sh : persistance de la version installée dans state.json.
- libs/version.sh : lecture et incrément de la version stockée dans version.
- libs/tools.sh : utilitaires génériques.
- config.conf.example : exemple de configuration.
- apt-mqtt.service : unité systemd d'exemple pour APT.
- docker-mqtt.service : unité systemd d'exemple pour Docker.
- install_service.sh : installe ou supprime l'unité systemd APT ou Docker avec les bons chemins.
- release_push.sh : incrémente la release puis pousse le dépôt.

## Dépendances

Paquets système requis sur Debian/Ubuntu :

```bash
sudo apt update
sudo apt install -y mosquitto-clients jq git systemd
```

Pour la supervision Docker Compose, Docker doit être installé avec la commande `docker compose` ou `docker-compose`.

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
- CHECK_INTERVAL : délai entre deux publications d'état.
- APT_MQTT_LOG_LEVEL : niveau de log parmi DEBUG, INFO, WARN, ERROR.

Le reste est fixé dans le code pour rester simple :

- apt_mqtt utilise la base de topic apt-update.
- docker_mqtt utilise la base de topic docker-update.
- les topics globaux sont codés en dur.
- les noms de services systemd sont codés en dur.
- le client_id MQTT est construit automatiquement à partir du hostname et du script.
- le répertoire d'installation est injecté par le service systemd au moment de l'installation.

Pour suivre l'exécution plus finement, vous pouvez mettre APT_MQTT_LOG_LEVEL=DEBUG dans la configuration.

## Supervision Docker Compose

Le daemon Docker ne cherche les fichiers que dans les chemins suivants :

- /root/docker-compose.yml
- /root/*/docker-compose.yml
- /home/mamath/docker-compose.yml
- /home/mamath/*/docker-compose.yml

Il ne scanne aucun autre répertoire.

Pour chaque stack trouvée, le daemon Docker :

- résout les images du compose avec leurs digests distants ;
- compare ces digests avec ceux actuellement déployés pour la stack ;
- publie une entité Home Assistant de type update dédiée ;
- accepte une commande de mise à jour qui exécute `docker compose pull --include-deps` puis `docker compose up -d`.

Comme pour APT, la version exposée à Home Assistant est une version logique persistée dans docker_state.json. Elle est incrémentée quand une mise à jour Docker est effectivement appliquée par le daemon.

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

Installation du service Docker MQTT :

```bash
sudo ./install_service.sh install --docker
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
sudo ./install_service.sh status --docker
sudo ./install_service.sh status -f
```

Suppression du service :

```bash
sudo ./install_service.sh remove
sudo ./install_service.sh remove --docker
```

## MQTT exposé

Pour un hostname sanitizé my-host :

- APT état : apt-update/my-host/state
- APT attributs : apt-update/my-host/attributes
- APT commandes : apt-update/my-host/command
- APT disponibilité : apt-update/my-host/availability
- Docker commandes : docker-update/my-host/command
- Docker disponibilité : docker-update/my-host/availability
- Docker global : docker-update/global/update

Commandes acceptées sur le topic APT :

- install, update, upgrade : lance apt-get update puis apt-get -y dist-upgrade
- dry-run, simulate : simulation sans changement
- check, status : republie l'état immédiatement
- self-update, update-script, update-scripts, git-pull : fait un git pull puis redémarre le service

Commandes acceptées sur le topic Docker :

- docker-install:<stack-id> : met à jour une stack Docker Compose précise
- pull-all, docker-install-all, update-all : met à jour toutes les stacks détectées sur l'hôte
- check, status : republie l'état immédiatement

Le device principal APT publie aussi un bouton Home Assistant qui envoie self-update sur le topic global configuré. Le daemon APT exécute alors le git pull du dépôt puis redémarre son propre service. S'il détecte qu'un service Docker MQTT est installé sur l'hôte, il le redémarre aussi.

Home Assistant n'expose plus qu'un seul device principal : le main device APT MQTT.

Le device principal APT publie aussi un bouton global Docker pull-all qui envoie un message sur le topic Docker global. Chaque daemon Docker abonné exécute alors une mise à jour de toutes les stacks détectées sur son hôte.

Les entités Docker Compose sont publiées sur un device Home Assistant dédié par hôte, lié au main device APT MQTT via via_device, avec un topic dédié par stack sous la forme `docker-update/<host>/docker/<stack-id>/state` et `docker-update/<host>/docker/<stack-id>/attributes`.

## Version du script

La version du code est stockée dans le fichier [version](version) et publiée dans Home Assistant via un sensor diagnostic associé au device de chaque hôte.

Pour incrémenter automatiquement la release avant un push, utilisez :

```bash
./release_push.sh
```

Ce script incrémente le patch de version, commit le fichier version puis pousse le dépôt.

## Documentation détaillée

Voir [docs/fonctionnement.md](docs/fonctionnement.md) pour le fonctionnement interne, le format des messages et les choix de structure.

