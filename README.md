# scripts/update_apt.sh

Petit script pour mettre à jour les paquets APT.

Exemples d'utilisation:

Rendre exécutable:

```bash
chmod +x scripts/update_apt.sh
```

Simulation (dry-run):

```bash
sudo scripts/update_apt.sh --dry-run
```

Mettre à jour (demande confirmation interactive):

```bash
sudo scripts/update_apt.sh
```

Mise à jour complète non interactive + nettoyage:

```bash
sudo scripts/update_apt.sh --yes --full-upgrade --autoremove
```

Remarque: exécuter les opérations réelles nécessite des privilèges root (sudo).

---


**Démon MQTT (Bash) pour Home Assistant**

J'ai ajouté un démon Bash qui publie via MQTT une entité `update` et un `button` pour déclencher les mises à jour APT (sans Python).

- Fichiers ajoutés: `apt_mqtt/apt_mqtt_daemon.sh`, `apt_mqtt/requirements.txt`, `apt_mqtt/apt-mqtt.service`

Dépendances système (Debian/Ubuntu):

```bash
sudo apt update
sudo apt install -y mosquitto-clients jq
```

Configuration minimale:

1. Rendre exécutable:

```bash
chmod +x apt_mqtt/apt_mqtt_daemon.sh
```

2. Lancer manuellement (exemple):

```bash
sudo ./apt_mqtt/apt_mqtt_daemon.sh
```

3. Installer en service systemd (exemple):

```bash
sudo cp apt_mqtt/apt-mqtt.service /etc/systemd/system/apt-mqtt.service
sudo systemctl daemon-reload
sudo systemctl enable --now apt-mqtt.service
```

Configuration via fichier / variables d'environnement:
- `MQTT_BROKER` (default `localhost`)
- `MQTT_PORT` (default `1883`)
- `MQTT_BASE_TOPIC` (default `home/apt`)
- `MQTT_USERNAME` / `MQTT_PASSWORD` si nécessaire
- `CHECK_INTERVAL` (en secondes, défaut 3600)

Notes:
- Le démon publie la découverte MQTT Home Assistant (préfixe `homeassistant`) et crée une entité `update` par serveur. Le `device` publié est global et représente le script d'update (nom par défaut: "APT Updater", identifiant = `OBJECT_ID`). Chaque entité `update` est nommée par le `hostname` du serveur et peut être cliquée depuis l'interface Home Assistant pour lancer l'installation.
- Le démon écoute le `command_topic` et attend le payload `install`; lorsqu'il le reçoit, il exécute `apt-get update` puis `apt-get -y upgrade`.
- Le démon publie sur `<base-topic>/<hostname>/state` un payload JSON contenant `installed_version`, `latest_version`, `in_progress` et `last_check`. Les attributs détaillés (liste des paquets upgradables, etc.) sont publiés sur `<base-topic>/<hostname>/attributes`.
- Exécuter le service en tant que `root` ou donner les droits nécessaires pour appeler `apt-get`.

Sécurité:
- Configurez l'authentification MQTT (variables d'environnement `MQTT_USERNAME` / `MQTT_PASSWORD`) si votre broker l'exige.

