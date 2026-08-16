clear
echo "═══════════════════════════════════════════════════════════"
echo "  DRY RUN : Ce qui va être SUPPRIME"
echo "═══════════════════════════════════════════════════════════"

echo ""
echo "──── Services Swarm nephro-backend / transplantation-backend ────"
docker service ls --format 'table {{.Name}}\t{{.Replicas}}\t{{.Image}}' \
  | grep -E 'nephro.*backend|transplantation.*backend'

echo ""
echo "──── Tous conteneurs (Running+Exited) liés ───────────────────────"
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.ID}}' \
  | grep -E 'nephro.*backend|transplantation.*backend|sadhub/transplantation-backend'

echo ""
echo "──── Images Docker liées ─────────────────────────────────────────"
docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}' \
  | grep -E 'sadhub/transplantation-backend'

echo ""
echo "──── Volumes nommés (uploads nephro) ─────────────────────────────"
docker volume ls --format 'table {{.Name}}\t{{.Driver}}' \
  | grep -iE 'nephro.*upload|transplantation.*upload|zv5cw6'