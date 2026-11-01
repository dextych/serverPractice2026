import express from 'express';
import { config } from '#config';
import './src/models/index.js';
import sequeize from './config/sequelize.js';
import routes from './src/routes/index.js';
import { errorHandler } from './src/infrastructure/errors/errorHandler.js';

const app = express();
app.use(express.json());

app.get('/', (req, res) => {
  res.json({ 
    status: 'success', 
    message: 'Сервер управления сетью и overlay-маршрутами запущен' 
  });
});

app.use('/api', routes);
app.use(errorHandler);

// Запуск сервера
try{
    await sequeize.authenticate();
    console.log("Db connect");

    app.listen(config.port, () => {
    console.log(`Сервер успешно запущен: http://localhost:${config.port}`);
    });
} catch(error){
    console.error('Server init error: ', error);
}