# homeapi.example.com app
# foward to a docker running on the machine, with the homeapi app

server {
    listen 80;

    server_name homeapi.example.com;
    

    access_log /var/log/nginx/nginx.vhost.access.log;
    error_log /var/log/nginx/nginx.vhost.error.log;

    location / {
        proxy_pass http://localhost:8081/;
    }  
}