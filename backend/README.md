```
docker build --tag web-app-backend:latest .
docker login
docker tag web-app-backend:latest jomadu/web-app-backend:latest
docker push jomadu/web-app-backend:latest
```
