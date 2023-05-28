FROM busybox

RUN adduser -D static
USER static
WORKDIR /home/static

# Run BusyBox httpd
CMD ["busybox", "httpd", "-f", "-v", "-p", "3000"]