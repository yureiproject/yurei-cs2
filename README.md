# Yurei — CS2 Team Hub

Application Windows pour l’équipe Yurei. L’application utilise Supabase Auth et PostgreSQL pour les comptes et données partagées, Supabase Storage pour les médias, et la fonction Edge yurei-stats pour les statistiques FACEIT et Leetify.

## Sécurité

- Les mots de passe sont gérés par Supabase Auth, jamais par une table SQL.
- Les profils, rôles, plannings, disponibilités et routines sont dans PostgreSQL avec RLS.
- Les clés FACEIT et Leetify sont conservées chiffrées dans Supabase Vault.
- Seule la clé publishable Supabase est intégrée au client. N’ajoute jamais une clé service_role, sb_secret, API ou un jeton GitHub au code.

## Créer le premier compte admin

1. Dans Supabase Dashboard → SQL Editor, ouvre supabase/authorize_first_admin.sql et remplace REPLACE-WITH-YOUR-ADMIN-EMAIL par ton adresse.
2. Dans Authentication → URL Configuration → Redirect URLs, ajoute yurei://auth/callback et yurei://reset-password.
3. Installe une fois Yurei depuis la release GitHub, puis crée un compte avec cette adresse et confirme l’e-mail.
4. Choisis Créer le premier compte administrateur, puis configure ton profil FACEIT, ton SteamID64 et les clés développeur FACEIT et Leetify.
5. Dans Paramètres, génère un code d’invitation à usage unique pour chaque joueur. Le code expire après 7 jours.

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
