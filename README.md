# APT MQTT Daemon

Ce projet fournit un démon Bash qui surveille les mises à jour APT disponibles et expose cet état via MQTT pour Home Assistant.

Si Docker Compose est disponible sur l'hôte, le démon expose aussi une entité update Home Assistant par stack docker-compose détectée dans un périmètre strict.

Le démon publie :

- une entité Home Assistant de type update via MQTT Discovery ;
- un état périodique avec les paquets upgradables ;
- une commande MQTT permettant de lancer une mise à jour APT à distance.

## Structure

- apt_mqtt_daemon.sh : boucle principale du démon.
- libs/config.sh : chargement de la configuration et calcul des topics MQTT.
- libs/mqtt.sh : publication MQTT et payload de discovery Home Assistant.
- libs/apt.sh : interrogation APT et exécution des mises à jour.
- libs/docker.sh : détection des stacks Docker Compose, résolution des digests d'images et mise à jour des stacks.
- libs/git.sh : mise à jour du dépôt et redémarrage du service.
- libs/state.sh : persistance de la version installée dans state.json.
- libs/version.sh : lecture et incrément de la version stockée dans version.
- libs/tools.sh : utilitaires génériques.
- config.conf.example : exemple de configuration.
- apt-mqtt.service : unité systemd d'exemple.
- install_service.sh : installe ou supprime l'unité systemd avec les bons chemins.
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
- MQTT_BASE_TOPIC : racine des topics publiés.
- MQTT_GLOBAL_UPDATE_TOPIC : topic global du bouton de mise à jour des scripts.
- OBJECT_ID : identifiant de l'entité Home Assistant.
- CHECK_INTERVAL : délai entre deux publications d'état.
- APT_MQTT_SERVICE_NAME : nom du service systemd à redémarrer après git pull.
- APT_MQTT_INSTALL_DIR : répertoire du dépôt local à mettre à jour.

Le hostname est normalisé puis ajouté automatiquement au topic de base.

## Supervision Docker Compose

Si Docker Compose est disponible, le démon ne cherche les fichiers que dans les chemins suivants :

- /root/docker-compose.yml
- /root/*/docker-compose.yml
- /home/mamath/docker-compose.yml
- /home/mamath/*/docker-compose.yml

Il ne scanne aucun autre répertoire.

Pour chaque stack trouvée, le démon :

- résout les images du compose avec leurs digests distants ;
- compare ces digests avec ceux actuellement déployés pour la stack ;
- publie une entité Home Assistant de type update dédiée ;
- accepte une commande de mise à jour qui exécute `docker compose pull --include-deps` puis `docker compose up -d`.

Comme pour APT, la version exposée à Home Assistant est une version logique persistée dans state.json. Elle est incrémentée quand une mise à jour Docker est effectivement appliquée par le démon.

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
- docker-install:<stack-id> : met à jour une stack Docker Compose précise
- check, status : republie l'état immédiatement
- self-update, update-script, update-scripts, git-pull : fait un git pull puis redémarre le service

Le device principal publie aussi un bouton Home Assistant qui envoie self-update sur le topic global configuré. Chaque daemon abonné à ce topic exécute alors le git pull de son répertoire d'installation puis redémarre son service.

Les entités Docker Compose sont publiées sur le device de l'hôte, avec un topic dédié par stack sous la forme `.../docker/<stack-id>/state` et `.../docker/<stack-id>/attributes`.

## Version du script

La version du code est stockée dans le fichier [version](version) et publiée dans Home Assistant via un sensor diagnostic associé au device de chaque hôte.

Pour incrémenter automatiquement la release avant un push, utilisez :

```bash
./release_push.sh
```

Ce script incrémente le patch de version, commit le fichier version puis pousse le dépôt.

## Documentation détaillée

Voir [docs/fonctionnement.md](docs/fonctionnement.md) pour le fonctionnement interne, le format des messages et les choix de structure.

