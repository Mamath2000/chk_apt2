# Fonctionnement du projet

## Vue d'ensemble

Le projet implémente un démon Bash qui expose l'état des mises à jour APT d'une machine Linux via MQTT. Il vise un usage avec Home Assistant en s'appuyant sur MQTT Discovery.

Le cycle général est le suivant :

1. Le script charge sa configuration.
2. Il publie la configuration MQTT Discovery Home Assistant.
3. Il publie régulièrement l'état courant des mises à jour disponibles.
4. Il écoute un topic de commande MQTT.
5. Lorsqu'une commande d'installation arrive, il exécute les commandes APT puis republie l'état.

## Organisation du code

La logique a été découpée par responsabilité :

- apt_mqtt_daemon.sh : orchestration, boucle principale, gestion du FIFO de souscription et coordination des appels.
- libs/config.sh : lecture du fichier de configuration, application des valeurs par défaut, construction des topics dérivés.
- libs/mqtt.sh : encapsulation de mosquitto_pub / mosquitto_sub et publication du payload Home Assistant.
- libs/apt.sh : lecture des paquets upgradables, exécution de apt-get update, dist-upgrade et autoremove.
- libs/git.sh : git pull local et redémarrage du service systemd.
- libs/state.sh : lecture et écriture de state.json pour conserver une version installée stable côté Home Assistant.
- libs/version.sh : gestion du fichier version et incrément de la release.
- libs/tools.sh : fonctions génériques réutilisables, comme la vérification root, les dépendances et la normalisation du hostname.
- install_service.sh : génération et suppression de l'unité systemd avec chemins absolus corrects.

Cette séparation permet de limiter les effets de bord dans le script principal et rend chaque responsabilité plus simple à tester manuellement.

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

Le topic de base final suit la forme :

```text
<MQTT_BASE_TOPIC>/<hostname-sanitized>
```

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

La version installée est volontairement persistée dans state.json. Cela évite qu'une nouvelle valeur soit générée à chaque redémarrage du démon.

## Déclenchement des mises à jour

Le démon ouvre une souscription MQTT sur le topic de commande propre à l'hôte et sur le topic global configuré. Les payloads suivants sont interprétés :

- install, update, upgrade, upgrade-all : exécution réelle
- dry-run, simulate : simulation via apt-get -s dist-upgrade
- check, status : publication immédiate de l'état
- self-update, update-script, update-scripts, git-pull : git pull du dépôt local puis redémarrage du service

Lors d'une mise à jour réelle, le flux est :

1. Création d'un marqueur local pour signaler qu'une mise à jour est en cours.
2. Exécution de apt-get update.
3. Exécution de apt-get -y dist-upgrade.
4. Exécution éventuelle de apt-get -y autoremove si activée.
5. Mise à jour de state.json si l'opération a réussi.
6. Suppression du marqueur puis publication des attributs d'exécution et de l'état final.

## Commandes globales

Le device principal expose des boutons Home Assistant qui publient sur le topic global configuré.

Chaque daemon est abonné à ce topic global en plus de son topic de commande propre à l'hôte.

- self-update : lance git pull --ff-only dans le répertoire d'installation configuré, republie ses attributs et sa version, puis redémarre le service systemd configuré.
- upgrade-all : lance le même flux que install/update/upgrade, donc apt-get update puis apt-get -y dist-upgrade sur chaque hôte abonné.

Le bouton principal `upgrade-all` permet donc de déclencher une mise à jour APT sur tous les daemons qui écoutent ce topic global.

## Version du script

Le fichier [version](version) contient la version logique du script déployé.

Cette version est :

- lue au démarrage et pendant les publications MQTT ;
- publiée dans un sensor Home Assistant de diagnostic lié au device de l'hôte ;
- incrémentée via le script release_push.sh avant envoi au dépôt distant.

## Points d'attention

- Le script doit être exécuté avec les privilèges nécessaires pour lancer apt-get.
- state.json est stocké dans le répertoire du projet. Si vous préférez un emplacement système, il faudra adapter libs/state.sh.
- Le service systemd fourni utilise un chemin absolu. Il peut être nécessaire de l'ajuster selon l'emplacement réel du projet.
- Les dépendances listées dans requirements.txt sont en pratique des paquets système et non des dépendances Python.

## Installation du service

Le script install_service.sh génère le fichier /etc/systemd/system/apt-mqtt.service à partir de l'emplacement réel du projet.

Il inscrit :

- WorkingDirectory avec le chemin absolu du projet ;
- ExecStart avec le chemin absolu de apt_mqtt_daemon.sh ;
- Environment=APT_MQTT_CONFIG=... pour pointer explicitement vers le bon fichier de configuration.

Par défaut, le script choisit le premier fichier lisible parmi :

1. ./config.conf
2. /etc/apt_mqtt/config.conf
3. $HOME/.config/apt_mqtt/config.conf

Un autre chemin peut être imposé via l'option --config.

Le script expose aussi :

- install -f : installe puis enchaîne sur systemctl status -f apt-mqtt.service ;
- status : affiche l'état courant du service ;
- status -f : suit le service en direct.

## Évolutions possibles

- Déplacer les chemins et comportements avancés dans la configuration plutôt que dans le script.
- Ajouter une journalisation structurée vers syslog ou journald.
- Ajouter un verrou pour éviter plusieurs mises à jour concurrentes si plusieurs commandes arrivent très vite.
- Ajouter un mode debug configurable.