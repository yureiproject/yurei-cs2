# Yurei — CS2 Team Hub

Application Windows pour l’équipe Yurei. L’application utilise Supabase Auth et PostgreSQL pour les comptes et données partagées, Supabase Storage pour les médias, et la fonction Edge yurei-stats pour les statistiques FACEIT et Leetify.

## Sécurité

- Les mots de passe sont gérés par Supabase Auth, jamais par une table SQL.
- Les profils, rôles, plannings, disponibilités et routines sont dans PostgreSQL avec RLS.
- Les clés FACEIT et Leetify sont conservées chiffrées dans Supabase Vault.
- Seule la clé publishable Supabase est intégrée au client. N’ajoute jamais une clé service_role, sb_secret, API ou un jeton GitHub au code.

## Créer le premier compte admin

1. Dans Supabase Dashboard → SQL Editor, ouvre `supabase/authorize_first_admin.sql` et remplace le placeholder par ton adresse.
2. Dans Authentication → URL Configuration → Redirect URLs, ajoute `yurei://auth/callback` et `yurei://reset-password`.
3. Dans Authentication → Providers → Email, désactive Confirm email si tu veux créer les comptes sans validation par e-mail. Ce réglage est côté Supabase Auth et ne peut pas être changé par l’application.
4. Crée le compte de l’adresse autorisée. Le premier admin est contrôlé par la liste SQL; l’application ne propose aucun bouton public pour créer un admin.
5. Dans Paramètres, génère un code d’invitation à usage unique pour chaque joueur. Le code expire après 7 jours.

## Appliquer les permissions et la synchronisation live

Après le schéma de base, exécute `supabase/migrations/20261013_permissions_realtime.sql` dans Supabase Dashboard → SQL Editor. Cette migration fixe les cinq rôles, les droits de création d’événements, l’accès d’écriture admin aux médias et l’abonnement Realtime. Elle doit être appliquée avant d’utiliser ces nouvelles autorisations.

## Installer et lancer en développement

Node.js LTS est requis pour construire l’application. Lance build-desktop.bat pour créer un installateur dans release/ ou run-desktop.bat pour la démarrer en développement.

## Mises à jour automatiques

Le dépôt yureiproject/yurei-cs2 est public pour distribuer les versions. Yurei vérifie les mises à jour au démarrage, les télécharge en arrière-plan et les installe à la fermeture. Supabase continue de gérer les comptes et les données.

Le workflow .github/workflows/release-windows.yml construit l’installateur Windows et publie les fichiers requis par l’auto-updater à chaque release vX.Y.Z. GitHub fournit automatiquement au workflow son jeton de publication; aucun jeton personnel n’est nécessaire.

Pour publier une nouvelle version :

1. Augmente version dans package.json (par exemple 1.0.2).
2. Committe et pousse les changements sur main.
3. Crée une release avec un tag correspondant exactement, par exemple v1.0.2.

La release doit inclure l’installateur, latest.yml et le fichier .blockmap. Les personnes installées sur une ancienne version la recevront au prochain démarrage et l’installation se terminera à la fermeture de Yurei.

La première installation doit se faire une fois depuis la release GitHub. Après cela, les mises à jour sont automatiques.

## Limites Supabase

Le bucket privé limite un fichier à 50 Mo. Le service gratuit Supabase peut mettre la base en pause après une période d’inactivité.
