# Pinned. Upstream publishes a rolling :latest that changes daily, and every
# competing SearXNG listing builds off it, so two deploys of the same template
# a week apart are not the same application.
FROM docker.io/searxng/searxng:2026.8.3-aa059419f

# Replaces the upstream template the entrypoint copies into /etc/searxng on
# first boot. Enabling the JSON/CSV/RSS response formats is only possible in
# this file: settings_loader.py exposes no environment variable for
# search.formats, and the stock value of [html] makes every API call 403.
COPY settings.template.yml /usr/local/searxng/settings.template.yml

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
