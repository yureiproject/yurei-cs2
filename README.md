# Yurei — CS2 Team Hub

## Transition vers Flutter

Le nouveau socle Windows se trouve dans [`flutter_app/README.md`](flutter_app/README.md). Il utilise une fenêtre et un installateur Flutter Windows, tout en embarquant temporairement l'interface actuelle dans WebView2 pour ne pas casser les comptes, les pages, Supabase, FACEIT, Leetify et les médias partagés. Les écrans seront migrés progressivement vers des widgets Flutter; l'esthétique sera définie ensuite ensemble. L'ancienne version Electron reste disponible pendant la compilation et la vérification du nouveau logiciel.

Le correctif des appels Leetify se trouve dans `supabase/functions/yurei-stats/index.ts` : l’API v3 reçoit `steamId` (SteamID64), et la réponse d’historique accepte les deux formats documentés. Après connexion au CLI Supabase, lance `supabase/deploy-stats.bat` pour publier cette correction sur le projet Yurei; le code local ne modifie pas à lui seul la fonction déjà hébergée.

Application d’équipe Counter-Strike 2. L’interface affiche le logo `yurei.png` et se connecte au projet Supabase **Yurei app** (`dziwedssqmojnhbsjslz`, région `eu-west-1`).

## Données et sécurité

- Les comptes et mots de passe passent par **Supabase Auth**. N’insère jamais de mot de passe dans une table SQL.
- Les profils, rôles, plannings, disponibilités, routines et données d’équipe sont dans PostgreSQL (`team_members`, `team_state`, etc.), avec RLS.
- Les vidéos et images Maps vont dans le stockage privé Supabase; leur index est synchronisé dans les données d’équipe.
- Les clés FACEIT et Leetify sont validées par la fonction `yurei-stats`, puis conservées chiffrées dans Supabase Vault. Les statistiques sont demandées à ces API à la connexion/actualisation.
- La clé publishable intégrée au site est publique par conception. La clé `service_role`/`sb_secret` ne doit jamais être mise dans le navigateur.

La base et la fonction Edge sont installées. **Il n’y a pas encore de compte admin, de compte joueur ou de données d’équipe.** Les comptes et données de l’ancienne version SQLite n’ont pas été importés.

## Créer le premier compte administrateur

1. Ouvre `supabase/authorize_first_admin.sql`, remplace `REPLACE-WITH-YOUR-ADMIN-EMAIL` par l’e-mail que tu vas utiliser, puis exécute ce script dans **Supabase Dashboard → SQL Editor**. Il autorise uniquement cette adresse à créer le premier admin.
2. Dans **Authentication → URL Configuration → Redirect URLs**, ajoute ces deux URLs à la liste des redirections autorisées : `yurei://auth/callback` (confirmation d’e-mail) et `yurei://reset-password` (mot de passe oublié).
3. Lance `build-desktop.bat` pour créer l’installateur, ou `run-desktop.bat` pour démarrer la version de développement.
4. Choisis **Créer un compte**, inscris-toi avec l’e-mail autorisé, puis confirme l’e-mail si Supabase le demande et reconnecte-toi.
5. Sur l’écran de configuration, choisis **Créer le premier compte administrateur**. Le nom **Yurei** est prérempli. Renseigne ton profil FACEIT, ton SteamID64, puis les clés développeur FACEIT et Leetify. L’application les teste avant de les enregistrer.
6. Dans **Paramètres**, génère un code d’invitation pour chaque joueur. Le code ne fonctionne qu’une fois et expire après 7 jours. Le joueur crée son compte, confirme son e-mail, se connecte et saisit ce code.

Supabase confirme parfois les e-mails avant d’ouvrir une session. Le lien de confirmation revient au logiciel via le protocole `yurei://`; si cela échoue, vérifie la redirection autorisée à l’étape 2 et que l’application est installée.

## Logiciel Windows et mises à jour

Yurei est empaqueté comme application Windows Electron installée (fenêtre native et installateur NSIS). Le logiciel continue d’utiliser Supabase Auth, la base PostgreSQL, le stockage partagé et la fonction Edge `yurei-stats`; FACEIT et Leetify restent interrogés par les mêmes fonctions sécurisées. Aucun secret API ni clé `service_role` n’est embarqué dans le logiciel.

### Première installation pour le développement

1. Installe Node.js LTS sur le PC qui construit Yurei.
2. Dans Supabase Dashboard → Authentication → URL Configuration → Redirect URLs, ajoute `yurei://auth/callback` et `yurei://reset-password` afin que les liens d’e-mail reviennent dans le logiciel.
3. Ouvre `build-desktop.bat`. L’installateur Windows sera créé dans `release/`.
4. Exécute l’installateur pour vérifier l’application sur ton PC. `run-desktop.bat` lance la version de développement.

### Préparer le canal de mises à jour (une fois)

1. Crée un dépôt GitHub public `yurei-cs2` dans le compte `yureiproject` (la configuration du projet pointe déjà vers `yureiproject/yurei-cs2`). GitHub Releases sert uniquement à distribuer les mises à jour; Supabase continue de gérer les comptes et les données.
2. Crée un jeton GitHub avec accès `Contents: read and write` au dépôt et définis-le dans la variable d’environnement `GH_TOKEN` sur le PC qui publie les versions. Ne mets jamais ce jeton dans le code.
3. Construis le premier installateur avec `build-desktop.bat`, puis publie-le aux joueurs une seule fois. Dans Paramètres → Application de bureau, ils pourront ensuite vérifier, télécharger et installer les nouvelles versions.

Pour chaque nouvelle version, augmente `version` dans `package.json` puis lance `npm run release:win`. La version est publiée dans GitHub Releases; les logiciels installés la détectent, la téléchargent et proposent un redémarrage pour l’installer. Tu n’as pas à renvoyer l’installateur manuellement à toute l’équipe.

Le dépôt de versions doit rester public pour que tous les membres puissent télécharger les mises à jour sans jeton. Les données d’équipe, comptes, médias et statistiques restent dans les services Supabase existants.
## Limites

Le bucket Supabase privé limite un fichier à 50 Mo. La base gratuite Supabase peut être mise en pause après une période d’inactivité. Les statistiques ne s’affichent que si FACEIT/Leetify fournit les champs pour le profil.

- [Documentation des limites Supabase](https://supabase.com/docs/guides/platform/billing-on-supabase)
- [Documentation Supabase Auth](https://supabase.com/docs/guides/auth)
- [Déploiement Cloudflare Pages Direct Upload](https://developers.cloudflare.com/pages/get-started/direct-upload/)
