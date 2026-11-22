import { BrowserRouter, Routes, Route } from 'react-router-dom';
import Items from './pages/Items';

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/items" element={<Items />} />
      </Routes>
    </BrowserRouter>
  );
}
