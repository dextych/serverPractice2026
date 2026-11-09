# api/Dockerfile
FROM node:22-alpine

WORKDIR /app

# Копируем package.json и ставим зависимости
COPY package*.json ./
RUN npm install

# Копируем весь остальной код
COPY . .

# Открываем порт, указанный в конфигах
EXPOSE 3030

# Команда запуска сервера
CMD ["npm", "start"]