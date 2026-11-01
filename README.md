# iRessources

Portage natif macOS de [Resources](https://github.com/nokyan/resources), le moniteur système de GNOME, écrit en Swift / SwiftUI et s'appuyant directement sur les API de Darwin (Mach, IOKit, IOReport, libproc, SystemConfiguration, CoreWLAN).

L'interface reprend l'esprit de Resources : barre latérale avec un graphe par périphérique, pages « Usage » / « Properties » en listes encadrées, tableaux Apps et Processus avec barre d'action en bas.

## Fonctionnalités

| Page | Contenu |
| --- | --- |
| **Apps** | Applications ouvertes, regroupant tous leurs processus (y compris les helpers XPC, via le « processus responsable » comme dans le Moniteur d'activité). Mémoire, processeur, lecture/écriture disque, GPU. Quitter, forcer à quitter, masquer. |
| **Processes** | Tous les processus : PID, utilisateur, mémoire (empreinte physique), processeur, threads, E/S disque, GPU par processus. Terminer, tuer, suspendre, reprendre ; panneau de détails (ligne de commande, parent, temps CPU…). |
| **Processor** | Usage total et par cœur logique, type de cœur (Super/Performance/Efficacité), fréquence et activité par cluster, puissance (si exposée), cache, charge, température SoC, état thermique. |
| **Memory** | Utilisée / totale, swap, répartition (apps, câblée, compressée, cache), pression mémoire. |
| **GPU** | Usage (renderer/tiler), mémoire, fréquence et puissance (Apple silicon), nombre de cœurs. |
| **Neural Engine** | Puissance consommée par l'ANE (macOS ne publie pas de pourcentage d'utilisation). |
| **Drives** | Activité, débits lecture/écriture, volumes montés, interface, température NAND. |
| **Network** | Débits reçus/envoyés, adresses, Wi-Fi (signal, canal, norme, débit du lien). |
| **Battery** | Charge, puissance, santé, cycles, capacités, tension, température, adaptateur secteur. |

Quand la fenêtre est masquée, l'app rafraîchit au plus toutes les 5 s et coupe les collecteurs coûteux.

## Thèmes et animations

*Réglages › Appearance* propose les thèmes **Adwaita** (couleurs de Resources), **macOS**, **Pastel**, **Nord**, **Dracula**, **Solarized** et **Graphite**, ainsi que le mode clair, sombre ou automatique.

Deux niveaux d'animation, désactivables indépendamment :

- **Animations** (activé par défaut) : transitions de pages, surbrillance de la barre latérale, apparition du contenu. Coût quasi nul.
- **Animate live data** (désactivé par défaut) : défilement continu des graphes et chiffres qui roulent. Coûteux en CPU (voir ci-dessous).

Les deux respectent le réglage système *Accessibilité › Réduire les animations*.

## Sobriété

Mesures sur un MacBook Pro M5 Max, macOS 27, intervalle de 2 s, page Apps affichée (la plus coûteuse, avec ~1 150 processus) :

| Configuration | CPU (un cœur) | Mémoire |
| --- | --- | --- |
| Animations d'interface (défaut) | ~2,5 % | ~56 Mo |
| Sans animations | ~2,3 % | ~56 Mo |
| Données animées en direct | ~40 % | — |

Les points qui comptent :

- **Collecte à la demande** : la liste des processus, IOReport (puissance/fréquences) et les capteurs de température ne tournent que si la page affichée en a besoin.
- Un seul appel `proc_pidinfo(PROC_PIDTASKALLINFO)` par processus ; caches pour les chemins, les « processus responsables » et les noms d'utilisateur.
- La liste des applications n'est relue qu'au lancement ou à la fermeture d'une app (chaque propriété de `NSRunningApplication` peut déclencher un appel IPC à LaunchServices).
- Requêtes Wi-Fi et volumes mis en cache (respectivement 10 s et 15 s).
- Pas de `MTLDevice` : en créer un réserve plus de 100 Mo de mémoire GPU.
- Graphes dessinés avec des `Shape` (aucune vue par point), historique limité à 60 échantillons.

## Compilation

Nécessite Xcode 16 ou plus récent et macOS 15+.

```sh
scripts/build-app.sh          # produit build/iRessources.app (signature ad hoc)
open build/iRessources.app
```

Pour le développement : `swift run`. Pour voir ce qu'exposent les collecteurs sur une machine donnée, sans interface :

```sh
.build/debug/iRessources --dump
```

## Limites connues

- Sans privilèges root, macOS refuse les statistiques détaillées (CPU, E/S) des processus d'autres utilisateurs : elles apparaissent en « — ».
- Sur certaines puces, la consommation CPU et ANE n'est pas transmise aux processus non privilégiés ; l'app l'indique au lieu d'afficher 0 W.
- Les fréquences sont déduites des tables DVFS du gestionnaire d'alimentation, dont la disposition change selon la génération de SoC ; elles peuvent être approximatives.
- IOReport, les capteurs HID et `responsibility_get_pid_responsible_for_pid` sont des interfaces système non documentées (les mêmes que `powermetrics` ou le Moniteur d'activité) : l'app ne peut pas être publiée sur le Mac App Store.

## Licence

GPL-3.0-or-later, comme Resources. Voir [LICENSE](LICENSE).
