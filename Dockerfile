ARG PG_VERSION=18
FROM postgres:${PG_VERSION}-alpine

RUN apk add --no-cache aws-cli bash

COPY backup.sh /backup.sh
RUN chmod +x /backup.sh

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV BACKUP_CRON_SCHEDULE="0 2 * * *"

ENTRYPOINT ["/entrypoint.sh"]
CMD ["crond", "-f", "-l", "2", "-c", "/tmp/crontabs"]
