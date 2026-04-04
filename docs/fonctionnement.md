# Fonctionnement du projet

## Vue d'ensemble

Le projet implémente deux démons Bash distincts qui exposent l'état des mises à jour d'une machine Linux via MQTT. Il vise un usage avec Home Assistant en s'appuyant sur MQTT Discovery.

Le cycle général est le suivant :

1. Chaque script charge sa configuration.
2. Il publie la configuration MQTT Discovery Home Assistant correspondant à son périmètre.
3. Il publie régulièrement l'état courant des mises à jour disponibles.
4. Il écoute son ou ses topics de commande MQTT.
5. Lorsqu'une commande arrive, il exécute l'action correspondante puis republie l'état.

## Organisation du code

La logique a été découpée par responsabilité :

- apt_mqtt_daemon.sh : orchestration APT, boucle principale, gestion de la souscription MQTT et coordination des appels.
- docker_mqtt_daemon.sh : orchestration Docker Compose, boucle principale, gestion de la souscription MQTT et coordination des appels.
- libs/config.sh : lecture du fichier de configuration, application des valeurs par défaut, construction des topics dérivés.
- libs/mqtt.sh : encapsulation de mosquitto_pub / mosquitto_sub et publication du payload Home Assistant.
- libs/apt.sh : lecture des paquets upgradables, exécution de apt-get update, dist-upgrade et autoremove.
- libs/docker.sh : détection des stacks Docker Compose, résolution des images distantes et exécution de pull / up -d.
- libs/git.sh : git pull local et redémarrage du service systemd.
- libs/state.sh : lecture et écriture de state.json ou docker_state.json pour conserver une version installée stable côté Home Assistant.
- libs/version.sh : gestion du fichier version et incrément de la release.
- libs/tools.sh : fonctions génériques réutilisables, comme la vérification root, les dépendances et la normalisation du hostname.
- install_service.sh : génération et suppression de l'unité systemd avec chemins absolus corrects.

Cette séparation limite les effets de bord entre APT et Docker et permet d'installer les deux services côte à côte sans partager le même état d'exécution.

## Chargement de la configuration

Le démon lit un fichier shell-compatible contenant des lignes KEY=VALUE. Les emplacements testés sont :

1. la variable d'environnement APT_MQTT_CONFIG si elle est définie
2. /etc/apt_mqtt/config.conf
3. $HOME/.config/apt_mqtt/config.conf
4. config.conf à la racine du projet

Après chargement, le script calcule les variables dérivées :

- HOSTNAME : nom court de la machine
- HOST_SAFENAME : version nettoyée pour MQTT
- CLIENT_ID : identifiant client utilisé par mosquitto_pub et mosquitto_sub
- STATE_TOPIC, ATTR_TOPIC, CMD_TOPIC, AVAIL_TOPIC : topics complets
- VERSION_TOPIC : topic du sensor de version du script
- GLOBAL_UPDATE_TOPIC : topic global utilisé par le bouton de self-update
- DOCKER_GLOBAL_UPDATE_TOPIC : topic global utilisé par le bouton pull-all Docker
- LOG_LEVEL : niveau de journalisation effectif, calculé depuis APT_MQTT_LOG_LEVEL

Le fichier de configuration reste volontairement minimal et ne contient que :

- MQTT_BROKER
- MQTT_PORT
- MQTT_USERNAME / MQTT_PASSWORD
- CHECK_INTERVAL
- APT_MQTT_LOG_LEVEL

Le reste est codé en dur :

- base APT : apt-update
- base Docker : docker-update
- topic global APT : apt-update/global/update
- topic global Docker : docker-update/global/update
- services systemd : apt-mqtt.service et docker-mqtt.service
- client_id : construit automatiquement à partir du hostname et du script

Pour Docker Compose, le daemon Docker construit des topics dérivés supplémentaires pour chaque stack trouvée :

- <BASE_TOPIC>/docker/<stack-id>/state
- <BASE_TOPIC>/docker/<stack-id>/attributes

Les topics de base finaux suivent la forme :

```text
apt-update/<hostname-sanitized>
docker-update/<hostname-sanitized>
```

Les niveaux de logs supportés sont DEBUG, INFO, WARN et ERROR. En pratique :

- APT_MQTT_LOG_LEVEL=DEBUG active toutes les traces de diagnostic ;
- sans configuration, le niveau par défaut est INFO.

## Publication d'état

À chaque cycle, le démon exécute apt list --upgradable puis reconstruit un JSON contenant les paquets pouvant être mis à jour.

Le topic state contient un JSON léger :

```json
{
  "installed_version": "1.0.0",
  "latest_version": "1.0.1",
  "last_check": "2026-04-01T10:00:00Z",
  "in_progress": false
}
```

Le topic attributes contient plus de détails :

```json
{
  "count": 2,
  "packages": [
    {
      "name": "bash",
      "installed": "5.2.15-2",
      "candidate": "5.2.15-2+b2"
    }
  ],
  "last_check": "2026-04-01T10:00:00Z",
  "in_progress": false
}
```

La version installée APT est volontairement persistée dans state.json. Cela évite qu'une nouvelle valeur soit générée à chaque redémarrage du démon.

Pour Docker Compose, le même principe est utilisé avec une version logique par stack. Le fichier docker_state.json contient alors la version logique installée et les digests actuellement déployés pour chaque stack suivie.

## Supervision Docker Compose

La supervision Docker est optionnelle. Si Docker Compose n'est pas disponible, le daemon Docker continue de tourner mais ne publie aucun composant de stack.

Quand elle est disponible, la détection des fichiers est limitée strictement à :

- /root/docker-compose.yml
- /root/*/docker-compose.yml
- /home/mamath/docker-compose.yml
- /home/mamath/*/docker-compose.yml

Le démon n'explore aucun autre répertoire.

Pour chaque fichier docker-compose.yml trouvé, il crée une entité Home Assistant de type update sur le device de l'hôte.

La détection d'une nouvelle image disponible se fait ainsi :

1. lecture des services déclarés dans le fichier Compose ;
2. résolution des images distantes en digests avec `docker compose config --resolve-image-digests --format json` ;
3. lecture des digests réellement déployés pour les conteneurs de cette stack ;
4. comparaison entre digests déployés et digests distants.

Si au moins un service a un digest plus récent côté registre, l'entité update expose une latest_version logique supérieure à installed_version.

Lorsqu'une mise à jour Docker est déclenchée depuis Home Assistant, le démon exécute :

1. `docker compose pull --include-deps`
2. `docker compose up -d`
3. mise à jour de l'état persisté pour enregistrer les nouveaux digests déployés
4. incrément de la version logique de la stack si au moins une image avait une mise à jour disponible

## Déclenchement des mises à jour

Le daemon APT ouvre une souscription MQTT sur le topic de commande propre à l'hôte et sur le topic global configuré. Les payloads suivants sont interprétés :

- install, update, upgrade, upgrade-all : exécution réelle
- dry-run, simulate : simulation via apt-get -s dist-upgrade
- check, status : publication immédiate de l'état
- self-update, update-script, update-scripts, git-pull : git pull du dépôt local puis redémarrage du service

Le daemon Docker ouvre une souscription MQTT sur son topic dédié docker-update/<host>/command ainsi que sur un topic global Docker. Les payloads suivants sont interprétés :

- docker-install:<stack-id> : exécution d'une mise à jour Docker Compose ciblée
- pull-all, docker-install-all, update-all : exécution d'une mise à jour de toutes les stacks détectées sur l'hôte
- check, status : publication immédiate de l'état Docker

Lors d'une mise à jour réelle, le flux est :

1. Création d'un marqueur local pour signaler qu'une mise à jour est en cours.
2. Exécution de apt-get update.
3. Exécution de apt-get -y dist-upgrade.
4. Exécution éventuelle de apt-get -y autoremove si activée.
5. Mise à jour de state.json si l'opération a réussi.
6. Suppression du marqueur puis publication des attributs d'exécution et de l'état final.

## Commandes globales

Le device principal expose des boutons Home Assistant qui publient sur le topic global configuré.

Seul le daemon APT est abonné au topic global APT. Le daemon Docker est, lui, abonné à un topic global Docker distinct.

- self-update : lance git pull --ff-only dans le répertoire d'installation configuré, republie ses attributs et sa version, puis redémarre le service APT configuré. Si le service Docker MQTT est installé, il est redémarré juste avant.
- upgrade-all : lance le même flux que install/update/upgrade, donc apt-get update puis apt-get -y dist-upgrade sur chaque hôte abonné.

Le device principal APT expose aussi un bouton pull-all Docker qui publie sur DOCKER_GLOBAL_UPDATE_TOPIC.

Chaque daemon Docker qui reçoit cette commande déclenche une mise à jour de toutes les stacks détectées sur son hôte.

Le bouton principal `upgrade-all` permet donc de déclencher une mise à jour APT sur tous les daemons qui écoutent ce topic global.

## Version du script

Le fichier [version](version) contient la version logique du script déployé.

Cette version est :

- lue au démarrage et pendant les publications MQTT ;
- publiée dans un sensor Home Assistant de diagnostic lié au device de l'hôte ;
- incrémentée via le script release_push.sh avant envoi au dépôt distant.

## Points d'attention

- Le script doit être exécuté avec les privilèges nécessaires pour lancer apt-get.
- Le script doit aussi pouvoir interroger Docker s'il doit superviser des stacks Compose.
- state.json et docker_state.json sont stockés dans le répertoire du projet. Si vous préférez un emplacement système, il faudra adapter libs/state.sh.
- Le service systemd fourni utilise un chemin absolu. Il peut être nécessaire de l'ajuster selon l'emplacement réel du projet.
- Les dépendances listées dans requirements.txt sont en pratique des paquets système et non des dépendances Python.

## Installation du service

Le script install_service.sh génère soit /etc/systemd/system/apt-mqtt.service, soit /etc/systemd/system/docker-mqtt.service à partir de l'emplacement réel du projet.

Il inscrit :

- WorkingDirectory avec le chemin absolu du projet ;
- ExecStart avec le chemin absolu de apt_mqtt_daemon.sh ou docker_mqtt_daemon.sh ;
- Environment=APT_MQTT_CONFIG=... pour pointer explicitement vers le bon fichier de configuration.
- Environment=APT_MQTT_INSTALL_DIR=... pour injecter le répertoire d'installation du dépôt au daemon APT.

Par défaut, le script choisit le premier fichier lisible parmi :

1. ./config.conf
2. /etc/apt_mqtt/config.conf
3. $HOME/.config/apt_mqtt/config.conf

Un autre chemin peut être imposé via l'option --config.

Le script expose aussi :

- install -f : installe puis enchaîne sur systemctl status -f apt-mqtt.service ;
- install --docker : installe le service Docker MQTT ;
- status : affiche l'état courant du service ;
- status --docker : affiche l'état courant du service Docker MQTT ;
- status -f : suit le service en direct.

## Évolutions possibles

- Déplacer les chemins et comportements avancés dans la configuration plutôt que dans le script.
- Ajouter une journalisation structurée vers syslog ou journald.
- Ajouter un verrou pour éviter plusieurs mises à jour concurrentes si plusieurs commandes arrivent très vite.
- Ajouter un mode debug configurable.